//
//  PaneTree.swift
//  TerminalCore
//

import CoreGraphics
import Foundation

/// Which side of a target pane a dragged pane is dropped on, deciding where it
/// lands relative to that pane.
public enum PaneDropEdge {
    case left, right, top, bottom
}

/// The direction in which a split lays out its two children.
public enum PaneSplitAxis: String, Codable {
    case horizontal
    case vertical
}

/// A binary split in the pane tree. `fraction` is the first child's share of
/// the available axis after the divider gap is removed.
public struct PaneTreeSplit<Leaf: Identifiable>: Identifiable where Leaf.ID == UUID {
    public let id = UUID()
    public var axis: PaneSplitAxis
    public var fraction: CGFloat
    public var first: PaneTree<Leaf>
    public var second: PaneTree<Leaf>

    public init(
        axis: PaneSplitAxis, fraction: CGFloat,
        first: PaneTree<Leaf>, second: PaneTree<Leaf>
    ) {
        self.axis = axis
        self.fraction = fraction
        self.first = first
        self.second = second
    }
}

/// Pane layouts are recursive so every split subdivides the focused pane's own
/// rectangle. This is what lets a right split of the lower pane in a top/bottom
/// layout stay beside that lower pane instead of spanning the full tab height.
///
/// Generic over its leaf so the tree carries no notion of what a pane *holds* —
/// the app's `PaneContent` reaches terminals, editors, and web views, none of
/// which this arithmetic needs. Every operation here is identity and geometry,
/// which is what makes it testable without a window.
public indirect enum PaneTree<Leaf: Identifiable> where Leaf.ID == UUID {
    case pane(Leaf)
    case split(PaneTreeSplit<Leaf>)

    public var allPanes: [Leaf] {
        switch self {
        case .pane(let pane):
            return [pane]
        case .split(let split):
            return split.first.allPanes + split.second.allPanes
        }
    }

    public func contains(_ paneID: UUID) -> Bool {
        switch self {
        case .pane(let pane):
            return pane.id == paneID
        case .split(let split):
            return split.first.contains(paneID) || split.second.contains(paneID)
        }
    }

    /// Replaces `target` with a split containing it and `pane`.
    public func inserting(
        _ pane: Leaf, toward edge: PaneDropEdge, beside target: UUID
    ) -> PaneTree {
        switch self {
        case .pane(let existing):
            guard existing.id == target else { return self }
            let axis: PaneSplitAxis = edge == .left || edge == .right
                ? .horizontal : .vertical
            let insertedFirst = edge == .left || edge == .top
            return .split(PaneTreeSplit(
                axis: axis,
                fraction: 0.5,
                first: .pane(insertedFirst ? pane : existing),
                second: .pane(insertedFirst ? existing : pane)
            ))
        case .split(var split):
            if split.first.contains(target) {
                split.first = split.first.inserting(pane, toward: edge, beside: target)
            } else if split.second.contains(target) {
                split.second = split.second.inserting(pane, toward: edge, beside: target)
            }
            return .split(split)
        }
    }

    /// Removes a leaf and collapses its now-single-child parent.
    public func removingPane(_ paneID: UUID) -> (node: PaneTree?, pane: Leaf?) {
        switch self {
        case .pane(let pane):
            return pane.id == paneID ? (nil, pane) : (self, nil)
        case .split(var split):
            let firstResult = split.first.removingPane(paneID)
            if let removed = firstResult.pane {
                guard let first = firstResult.node else { return (split.second, removed) }
                split.first = first
                return (.split(split), removed)
            }
            let secondResult = split.second.removingPane(paneID)
            if let removed = secondResult.pane {
                guard let second = secondResult.node else { return (split.first, removed) }
                split.second = second
                return (.split(split), removed)
            }
            return (self, nil)
        }
    }

    public func settingFraction(of splitID: UUID, to fraction: CGFloat) -> PaneTree {
        switch self {
        case .pane:
            return self
        case .split(var split):
            if split.id == splitID {
                split.fraction = fraction
            } else {
                split.first = split.first.settingFraction(of: splitID, to: fraction)
                split.second = split.second.settingFraction(of: splitID, to: fraction)
            }
            return .split(split)
        }
    }

    public func fraction(of splitID: UUID) -> CGFloat? {
        switch self {
        case .pane:
            return nil
        case .split(let split):
            if split.id == splitID { return split.fraction }
            return split.first.fraction(of: splitID) ?? split.second.fraction(of: splitID)
        }
    }

    public func equalized() -> PaneTree {
        switch self {
        case .pane:
            return self
        case .split(var split):
            split.first = split.first.equalized()
            split.second = split.second.equalized()
            let firstSpan = split.first.spanCount(along: split.axis)
            let secondSpan = split.second.spanCount(along: split.axis)
            split.fraction = firstSpan / (firstSpan + secondSpan)
            return .split(split)
        }
    }

    /// Counts adjacent tiles along `axis`, treating a perpendicular subtree as
    /// one tile. This preserves the old equalize behavior for both flat rows
    /// and columns while leaving nested perpendicular groups evenly divided.
    private func spanCount(along axis: PaneSplitAxis) -> CGFloat {
        guard case .split(let split) = self, split.axis == axis else { return 1 }
        return split.first.spanCount(along: axis)
            + split.second.spanCount(along: axis)
    }

    public func ancestors(of paneID: UUID) -> [PaneSplitAncestor]? {
        switch self {
        case .pane(let pane):
            return pane.id == paneID ? [] : nil
        case .split(let split):
            if let descendants = split.first.ancestors(of: paneID) {
                return [PaneSplitAncestor(
                    id: split.id, axis: split.axis, paneIsInFirstChild: true
                )] + descendants
            }
            if let descendants = split.second.ancestors(of: paneID) {
                return [PaneSplitAncestor(
                    id: split.id, axis: split.axis, paneIsInFirstChild: false
                )] + descendants
            }
            return nil
        }
    }

    /// Computes absolute pane and divider rectangles for both the live layout
    /// and the tab-switcher thumbnail.
    public func geometry(in bounds: CGRect, gap: CGFloat) -> PaneTreeGeometry<Leaf> {
        var geometry = PaneTreeGeometry<Leaf>()
        appendGeometry(in: bounds, gap: gap, to: &geometry)
        return geometry
    }

    private func appendGeometry(
        in bounds: CGRect, gap: CGFloat, to geometry: inout PaneTreeGeometry<Leaf>
    ) {
        switch self {
        case .pane(let pane):
            geometry.panes.append(PaneTreePlacement(pane: pane, frame: bounds))
        case .split(let split):
            let fraction = min(max(split.fraction, 0), 1)
            switch split.axis {
            case .horizontal:
                let available = max(0, bounds.width - gap)
                let firstWidth = available * fraction
                let dividerX = bounds.minX + firstWidth
                split.first.appendGeometry(
                    in: CGRect(
                        x: bounds.minX, y: bounds.minY,
                        width: firstWidth, height: bounds.height
                    ),
                    gap: gap,
                    to: &geometry
                )
                geometry.dividers.append(PaneTreeDivider(
                    id: split.id,
                    axis: split.axis,
                    frame: CGRect(
                        x: dividerX, y: bounds.minY,
                        width: gap, height: bounds.height
                    ),
                    availableLength: available
                ))
                split.second.appendGeometry(
                    in: CGRect(
                        x: dividerX + gap, y: bounds.minY,
                        width: available - firstWidth, height: bounds.height
                    ),
                    gap: gap,
                    to: &geometry
                )
            case .vertical:
                let available = max(0, bounds.height - gap)
                let firstHeight = available * fraction
                let dividerY = bounds.minY + firstHeight
                split.first.appendGeometry(
                    in: CGRect(
                        x: bounds.minX, y: bounds.minY,
                        width: bounds.width, height: firstHeight
                    ),
                    gap: gap,
                    to: &geometry
                )
                geometry.dividers.append(PaneTreeDivider(
                    id: split.id,
                    axis: split.axis,
                    frame: CGRect(
                        x: bounds.minX, y: dividerY,
                        width: bounds.width, height: gap
                    ),
                    availableLength: available
                ))
                split.second.appendGeometry(
                    in: CGRect(
                        x: bounds.minX, y: dividerY + gap,
                        width: bounds.width, height: available - firstHeight
                    ),
                    gap: gap,
                    to: &geometry
                )
            }
        }
    }
}

public struct PaneSplitAncestor {
    public let id: UUID
    public let axis: PaneSplitAxis
    public let paneIsInFirstChild: Bool

    public init(id: UUID, axis: PaneSplitAxis, paneIsInFirstChild: Bool) {
        self.id = id
        self.axis = axis
        self.paneIsInFirstChild = paneIsInFirstChild
    }
}

public struct PaneTreePlacement<Leaf: Identifiable>: Identifiable where Leaf.ID == UUID {
    public var id: UUID { pane.id }
    public let pane: Leaf
    public let frame: CGRect
}

public struct PaneTreeDivider: Identifiable {
    public let id: UUID
    public let axis: PaneSplitAxis
    public let frame: CGRect
    public let availableLength: CGFloat
}

public struct PaneTreeGeometry<Leaf: Identifiable> where Leaf.ID == UUID {
    public var panes: [PaneTreePlacement<Leaf>] = []
    public var dividers: [PaneTreeDivider] = []

    public init() {}
}
