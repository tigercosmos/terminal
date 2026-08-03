//
//  PaneTreeTests.swift
//  TerminalCore
//

import CoreGraphics
import Foundation
import Testing

@testable import TerminalCore

/// A leaf standing in for the app's `Pane`. The tree only ever reads a leaf's
/// identity, which is the whole reason it can be tested without one.
private struct TestLeaf: Identifiable, Equatable {
    let id = UUID()
    let name: String
}

private typealias Tree = PaneTree<TestLeaf>

/// Splitting, closing, focusing, and resizing panes are the most-used commands
/// in the app and the hardest to check by eye — a wrong `fraction` looks like a
/// slightly-off divider, and a wrong collapse looks like a pane that "went
/// somewhere". These pin the arithmetic down.
struct PaneTreeTests {
    private let a = TestLeaf(name: "a")
    private let b = TestLeaf(name: "b")
    private let c = TestLeaf(name: "c")

    /// Panes come back in tree order, which is the order focus cycles through
    /// and the order a restored layout is numbered in.
    @Test func panesComeBackInTreeOrder() {
        let tree = Tree.split(PaneTreeSplit(
            axis: .horizontal, fraction: 0.5,
            first: .pane(a),
            second: .split(PaneTreeSplit(
                axis: .vertical, fraction: 0.5, first: .pane(b), second: .pane(c)
            ))
        ))
        #expect(tree.allPanes == [a, b, c])
        #expect(tree.contains(c.id))
        #expect(!tree.contains(UUID()))
    }

    // MARK: - Inserting

    @Test func aLeftOrTopSplitPutsTheNewPaneFirst() {
        for edge in [PaneDropEdge.left, .top] {
            let tree = Tree.pane(a).inserting(b, toward: edge, beside: a.id)
            guard case .split(let split) = tree else {
                Issue.record("inserting should replace the leaf with a split")
                return
            }
            #expect(split.axis == (edge == .left ? .horizontal : .vertical))
            #expect(split.fraction == 0.5)
            #expect(tree.allPanes == [b, a])
        }
    }

    @Test func aRightOrBottomSplitPutsTheNewPaneSecond() {
        for edge in [PaneDropEdge.right, .bottom] {
            let tree = Tree.pane(a).inserting(b, toward: edge, beside: a.id)
            guard case .split(let split) = tree else {
                Issue.record("inserting should replace the leaf with a split")
                return
            }
            #expect(split.axis == (edge == .right ? .horizontal : .vertical))
            #expect(tree.allPanes == [a, b])
        }
    }

    /// Only the target leaf is subdivided — that is what keeps a right split of
    /// the lower pane beside that pane instead of spanning the tab.
    @Test func onlyTheTargetLeafIsSubdivided() {
        let row = Tree.pane(a).inserting(b, toward: .right, beside: a.id)
        let tree = row.inserting(c, toward: .bottom, beside: b.id)
        #expect(tree.allPanes == [a, b, c])
        guard case .split(let outer) = tree, case .split(let inner) = outer.second else {
            Issue.record("the second child should have become the nested split")
            return
        }
        #expect(outer.axis == .horizontal)
        #expect(inner.axis == .vertical)
        #expect(outer.first.allPanes == [a])
    }

    @Test func insertingBesideAPaneThatIsGoneChangesNothing() {
        let tree = Tree.pane(a).inserting(b, toward: .right, beside: UUID())
        #expect(tree.allPanes == [a])
    }

    // MARK: - Removing

    /// Closing one side of a split has to leave the sibling in the split's
    /// place, or the layout keeps a divider with nothing behind it.
    @Test func removingALeafCollapsesItsParent() {
        let tree = Tree.pane(a).inserting(b, toward: .right, beside: a.id)
        let result = tree.removingPane(a.id)
        #expect(result.pane == a)
        #expect(result.node?.allPanes == [b])
        if case .pane = result.node {} else {
            Issue.record("the surviving sibling should have replaced the split")
        }
    }

    @Test func removingTheLastLeafLeavesNoTree() {
        let result = Tree.pane(a).removingPane(a.id)
        #expect(result.pane == a)
        #expect(result.node == nil)
    }

    @Test func removingAPaneThatIsNotThereReportsNothingRemoved() {
        let tree = Tree.pane(a).inserting(b, toward: .right, beside: a.id)
        let result = tree.removingPane(UUID())
        #expect(result.pane == nil)
        #expect(result.node?.allPanes == [a, b])
    }

    /// A deep removal collapses only the split that lost a child.
    @Test func removingFromANestedSplitKeepsTheRestOfTheTree() {
        let row = Tree.pane(a).inserting(b, toward: .right, beside: a.id)
        let tree = row.inserting(c, toward: .bottom, beside: b.id)
        let result = tree.removingPane(c.id)
        #expect(result.pane == c)
        #expect(result.node?.allPanes == [a, b])
        guard case .split(let split) = result.node else {
            Issue.record("the outer split should survive")
            return
        }
        #expect(split.axis == .horizontal)
    }

    // MARK: - Fractions

    @Test func aFractionIsSetAndReadBackBySplitIdentity() {
        let tree = Tree.pane(a).inserting(b, toward: .right, beside: a.id)
        guard case .split(let split) = tree else { return }
        let resized = tree.settingFraction(of: split.id, to: 0.8)
        #expect(resized.fraction(of: split.id) == 0.8)
        // The original value is untouched: the tree is a value, and the app
        // relies on that when it publishes a new layout.
        #expect(tree.fraction(of: split.id) == 0.5)
        #expect(tree.fraction(of: UUID()) == nil)
    }

    @Test func aFractionInANestedSplitIsFound() {
        let row = Tree.pane(a).inserting(b, toward: .right, beside: a.id)
        let tree = row.inserting(c, toward: .bottom, beside: b.id)
        guard case .split(let outer) = tree, case .split(let inner) = outer.second else {
            return
        }
        let resized = tree.settingFraction(of: inner.id, to: 0.25)
        #expect(resized.fraction(of: inner.id) == 0.25)
        #expect(resized.fraction(of: outer.id) == 0.5)
    }

    // MARK: - Equalize

    /// Equalize means "every tile in this row gets the same width". Because the
    /// tree is binary, a three-pane row is a split whose second child holds two
    /// tiles — so its fraction has to be 1/3, not 1/2.
    @Test func equalizeGivesEveryTileInARowTheSameShare() {
        let row = Tree.pane(a)
            .inserting(b, toward: .right, beside: a.id)
        guard case .split(let firstSplit) = row else { return }
        let three = row.inserting(c, toward: .right, beside: b.id)
        let equalized = three.equalized()
        let oneThird: CGFloat = 1.0 / 3.0
        #expect(equalized.fraction(of: firstSplit.id) == oneThird)
        guard case .split(let outer) = equalized, case .split(let inner) = outer.second else {
            return
        }
        #expect(inner.fraction == 0.5)
    }

    /// A perpendicular subtree counts as one tile, so equalizing a row does not
    /// reach inside a column nested in it.
    @Test func equalizeTreatsAPerpendicularSubtreeAsOneTile() {
        let row = Tree.pane(a).inserting(b, toward: .right, beside: a.id)
        let tree = row.inserting(c, toward: .bottom, beside: b.id)
        guard case .split(let outer) = tree else { return }
        let equalized = tree.equalized()
        #expect(equalized.fraction(of: outer.id) == 0.5)
    }

    // MARK: - Ancestors

    /// Keyboard resize walks this list from the leaf outward to find the
    /// divider on the pressed side, so both the order and the side flag matter.
    @Test func ancestorsRunFromTheRootDownToTheLeaf() {
        let row = Tree.pane(a).inserting(b, toward: .right, beside: a.id)
        let tree = row.inserting(c, toward: .bottom, beside: b.id)
        guard case .split(let outer) = tree, case .split(let inner) = outer.second else {
            return
        }
        let ancestors = tree.ancestors(of: c.id)
        #expect(ancestors?.count == 2)
        #expect(ancestors?[0].id == outer.id)
        #expect(ancestors?[0].axis == .horizontal)
        #expect(ancestors?[0].paneIsInFirstChild == false)
        #expect(ancestors?[1].id == inner.id)
        #expect(ancestors?[1].paneIsInFirstChild == false)

        #expect(tree.ancestors(of: a.id)?.count == 1)
        #expect(tree.ancestors(of: a.id)?[0].paneIsInFirstChild == true)
        #expect(tree.ancestors(of: UUID()) == nil)
    }

    @Test func aSinglePaneHasNoAncestors() {
        #expect(Tree.pane(a).ancestors(of: a.id)?.isEmpty == true)
    }

    // MARK: - Geometry

    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 60)

    @Test func onePaneFillsTheBounds() {
        let geometry = Tree.pane(a).geometry(in: bounds, gap: 4)
        #expect(geometry.panes.count == 1)
        #expect(geometry.panes[0].frame == bounds)
        #expect(geometry.panes[0].id == a.id)
        #expect(geometry.dividers.isEmpty)
    }

    /// The gap is taken out of the axis *before* the fraction is applied, so
    /// the two panes plus the divider add back up to the bounds exactly.
    @Test func aSplitSpendsTheGapOnTheDividerAndNothingElse() {
        let tree = Tree.pane(a).inserting(b, toward: .right, beside: a.id)
        let geometry = tree.geometry(in: bounds, gap: 4)
        #expect(geometry.panes.count == 2)
        #expect(geometry.dividers.count == 1)

        let first = geometry.panes[0].frame
        let second = geometry.panes[1].frame
        let divider = geometry.dividers[0]
        #expect(first == CGRect(x: 0, y: 0, width: 48, height: 60))
        #expect(divider.frame == CGRect(x: 48, y: 0, width: 4, height: 60))
        #expect(second == CGRect(x: 52, y: 0, width: 48, height: 60))
        #expect(divider.axis == .horizontal)
        #expect(divider.availableLength == 96)
        #expect(first.width + divider.frame.width + second.width == bounds.width)
    }

    @Test func averticalSplitDividesTheHeightInstead() {
        let tree = Tree.pane(a).inserting(b, toward: .bottom, beside: a.id)
        let geometry = tree.geometry(in: bounds, gap: 10)
        #expect(geometry.panes[0].frame == CGRect(x: 0, y: 0, width: 100, height: 25))
        #expect(geometry.dividers[0].frame == CGRect(x: 0, y: 25, width: 100, height: 10))
        #expect(geometry.panes[1].frame == CGRect(x: 0, y: 35, width: 100, height: 25))
        #expect(geometry.dividers[0].axis == .vertical)
    }

    /// A fraction outside 0…1 can only come from a corrupt or hand-edited
    /// snapshot; it is clamped rather than allowed to place a pane off-screen.
    @Test func anOutOfRangeFractionIsClamped() {
        let tree = Tree.pane(a).inserting(b, toward: .right, beside: a.id)
        guard case .split(let split) = tree else { return }
        let wide = tree.settingFraction(of: split.id, to: 4)
            .geometry(in: bounds, gap: 0)
        #expect(wide.panes[0].frame.width == 100)
        #expect(wide.panes[1].frame.width == 0)

        let narrow = tree.settingFraction(of: split.id, to: -4)
            .geometry(in: bounds, gap: 0)
        #expect(narrow.panes[0].frame.width == 0)
        #expect(narrow.panes[1].frame.width == 100)
    }

    /// A gap wider than the axis would otherwise hand the panes a negative
    /// width, which lays out as a flipped rectangle.
    @Test func aGapWiderThanTheBoundsNeverYieldsANegativeWidth() {
        let tree = Tree.pane(a).inserting(b, toward: .right, beside: a.id)
        let geometry = tree.geometry(in: bounds, gap: 200)
        #expect(geometry.panes.allSatisfy { $0.frame.width >= 0 })
        #expect(geometry.dividers[0].availableLength == 0)
    }

    /// Every pane the tree holds gets exactly one placement, and they are
    /// handed back in tree order so the app can pair them with `allPanes`.
    @Test func nestedGeometryPlacesEveryPaneOnceInTreeOrder() {
        let row = Tree.pane(a).inserting(b, toward: .right, beside: a.id)
        let tree = row.inserting(c, toward: .bottom, beside: b.id)
        let geometry = tree.geometry(in: bounds, gap: 0)
        #expect(geometry.panes.map(\.id) == [a.id, b.id, c.id])
        #expect(geometry.dividers.count == 2)
        // The nested column is confined to the right half.
        #expect(geometry.panes[1].frame.minX == 50)
        #expect(geometry.panes[2].frame.minX == 50)
        #expect(geometry.panes[1].frame.height == 30)
    }
}
