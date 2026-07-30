//  Created by Marcin Krzyzanowski
//  https://github.com/krzyzanowskim/STTextView/blob/main/LICENSE.md

import AppKit
import STTextKitPlus
import CoreTextSwift
import STTextViewCommon

extension STTextView {

    /// This action method shows or hides the ruler, if the receiver is enclosed in a scroll view.
    @objc public func toggleRuler(_ sender: Any?) {
        isGutterVisible.toggle()
    }

    /// A Boolean value that controls whether the scroll view enclosing text views sharing the receiver’s layout manager displays the ruler.
    var isGutterVisible: Bool {
        set {
            if gutterView == nil, newValue == true {
                let gutterView = STGutterView()
                // estimate max gutter width
                gutterView.frame.origin = .zero
                gutterView.frame.size.width = max(gutterView.minimumThickness, CGFloat(textContentManager.length) / (1024 * 100))
                gutterView.frame.size.height = contentView.bounds.height
                gutterView.textColor = textColor.withAlphaComponent(0.45)
                gutterView.selectedLineTextColor = textColor
                gutterView.highlightSelectedLine = highlightSelectedLine
                gutterView.selectedLineHighlightColor = selectedLineHighlightColor
                gutterView.backgroundColor = backgroundColor
                if let enclosingScrollView {
                    enclosingScrollView.addFloatingSubview(gutterView, for: .horizontal)
                } else {
                    self.addSubview(gutterView)
                }
                self.gutterView = gutterView
                needsLayout = true
                layoutGutter()
            } else if newValue == false, let gutterView {
                gutterView.removeFromSuperview()
                self.gutterView = nil
                needsLayout = true
                layoutGutter()
            }
        }
        get {
            gutterView != nil
        }
    }

    func layoutGutter() {
        guard let gutterView, textLayoutManager.textViewportLayoutController.viewportRange != nil else {
            return
        }

        gutterView.frame.size.height = contentView.bounds.height

        layoutGutterLineNumbers()
        layoutGutterMarkers()
    }


    private func layoutGutterLineNumbers() {
        guard let gutterView else {
            return
        }

        gutterView.containerView.subviews.compactMap {
            $0 as? STGutterLineNumberCell
        }.forEach {
            $0.removeFromSuperviewWithoutNeedingDisplay()
        }

        let lineTextAttributes: [NSAttributedString.Key: Any] = [
            .font: gutterView.font,
            .foregroundColor: gutterView.textColor
        ]

        let selectedLineTextAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: (gutterView.selectedLineTextColor ?? gutterView.textColor).cgColor
        ]

        // if empty document
        if textLayoutManager.documentRange.isEmpty {
            if let selectionFrame = textLayoutManager.textSegmentFrame(at: textLayoutManager.documentRange.location, type: .standard) {
                let lineNumber = 1

                // Use typingAttributes to calculate baseline position for empty document.
                // The cell is sized for typingLineHeight, so baseline calculation should use typing font metrics
                // to match where text baseline would be. Line number is still drawn with gutter font.
                let ctNumberLine = CTLineCreateWithAttributedString(NSAttributedString(string: "\(lineNumber)", attributes: typingAttributes))
                let baselineParagraphStyle = typingAttributes[.paragraphStyle] as? NSParagraphStyle ?? defaultParagraphStyle
                let baselineOffset = -(ctNumberLine.typographicHeight() * (baselineParagraphStyle.stLineHeightMultiple - 1.0) / 2)

                var effectiveLineTextAttributes = lineTextAttributes
                if gutterView.highlightSelectedLine /* , isLineSelected */, !selectedLineTextAttributes.isEmpty {
                    effectiveLineTextAttributes.merge(selectedLineTextAttributes, uniquingKeysWith: { (_, new) in new })
                }

                let numberCell = STGutterLineNumberCell(
                    firstBaseline: ctNumberLine.typographicBounds().ascent - baselineOffset,
                    attributes: effectiveLineTextAttributes,
                    number: lineNumber
                )

                numberCell.insets = gutterView.insets

                if gutterView.highlightSelectedLine, textLayoutManager.textSelectionsRanges(.withoutInsertionPoints).isEmpty, !textLayoutManager.insertionPointSelections.isEmpty {
                    numberCell.layer?.backgroundColor = gutterView.selectedLineHighlightColor.cgColor
                }

                // For empty documents, ignore bounce scrolling by treating scroll offset as 0
                // Empty document fits in viewport, so any scroll is just bounce effect
                numberCell.frame = CGRect(
                    origin: CGPoint(
                        x: 0,
                        y: selectionFrame.origin.y
                    ),
                    size: CGSize(
                        width: gutterView.containerView.frame.width,
                        height: selectionFrame.height
                    )
                ).pixelAligned

                gutterView.containerView.addSubview(numberCell)
            }
        } else if let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange {
            // Get visible fragment views from the map and sort by document order
            // kero patch: after an attribute change (font/color) invalidates layout,
            // fragmentViewMap briefly holds both the old and new NSTextLayoutFragment
            // for the same range (the old one is kept alive by its detached fragment
            // view until the weak map purges). Numbering those stale entries shifts
            // every line number. Detached views are never visible, so drop them.
            let visibleFragmentViews = STGutterCalculations.visibleFragmentViewsInViewport(
                fragmentViewMap: fragmentViewMap,
                viewportRange: viewportRange
            ).filter { $0.1.superview != nil }

            guard !visibleFragmentViews.isEmpty else {
                return
            }

            // Calculate how many lines exist before the viewport.
            // terminal patch: this used `textContentManager.textElements(for:)`
            // over documentStart..<viewportStart, which materializes an
            // NSTextParagraph for every line above the viewport — O(document)
            // allocations on every layout pass. Opening a large file at a
            // restored scroll position took ~1s, and every scrolled layout
            // pass repaid the cost. Count paragraph separators in the backing
            // string instead, resuming from the previous viewport start so
            // scrolling only scans the delta.
            var requiredWidthFitText = gutterView.minimumThickness
            let startLineIndex = lineIndex(at: viewportRange.location)
            var linesCount = 0

            for (layoutFragment, fragmentView) in visibleFragmentViews {
                let contentRangeInElement = (layoutFragment.textElement as? NSTextParagraph)?.paragraphContentRange ?? layoutFragment.rangeInElement

                // Only show line numbers for the first line fragment or extra line fragments
                for textLineFragment in layoutFragment.textLineFragments where (textLineFragment.isExtraLineFragment || layoutFragment.textLineFragments.first == textLineFragment) {
                    let lineNumber = startLineIndex + linesCount + 1

                    // Determine if this line is selected
                    let isLineSelected = STGutterCalculations.isLineSelected(
                        textLineFragment: textLineFragment,
                        layoutFragment: layoutFragment,
                        contentRangeInElement: contentRangeInElement,
                        textLayoutManager: textLayoutManager
                    )

                    // Calculate positioning metrics
                    // Get the actual fragment view frame for pixel-perfect alignment
                    let (baselineYOffset, locationForFirstCharacter, cellFrame) = STGutterCalculations.calculateLineNumberMetrics(
                        for: textLineFragment,
                        in: layoutFragment,
                        fragmentViewFrame: fragmentView.frame
                    )

                    // Prepare text attributes
                    var effectiveLineTextAttributes = lineTextAttributes
                    if gutterView.highlightSelectedLine, isLineSelected, !selectedLineTextAttributes.isEmpty {
                        effectiveLineTextAttributes.merge(selectedLineTextAttributes, uniquingKeysWith: { (_, new) in new })
                    }
                    if let paragraphStyle = textLineFragment.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
                        effectiveLineTextAttributes[.paragraphStyle] = paragraphStyle
                    }

                    // Create and configure line number cell
                    let numberCell = STGutterLineNumberCell(
                        firstBaseline: locationForFirstCharacter.y + baselineYOffset,
                        attributes: effectiveLineTextAttributes,
                        number: lineNumber
                    )
                    numberCell.insets = gutterView.insets

                    // Apply selection highlight if needed
                    if gutterView.highlightSelectedLine, isLineSelected,
                       textLayoutManager.textSelectionsRanges(.withoutInsertionPoints).isEmpty,
                       !textLayoutManager.insertionPointSelections.isEmpty {
                        numberCell.layer?.backgroundColor = gutterView.selectedLineHighlightColor.cgColor
                    }

                    // Position the cell
                    numberCell.frame = CGRect(
                        origin: CGPoint(
                            x: 0,
                            y: cellFrame.origin.y
                        ),
                        size: CGSize(
                            width: gutterView.containerView.frame.width,
                            height: cellFrame.size.height
                        )
                    ).pixelAligned

                    gutterView.containerView.addSubview(numberCell)
                    requiredWidthFitText = max(requiredWidthFitText, numberCell.intrinsicContentSize.width)
                    linesCount += 1
                }
            }

            // adjust ruleThickness to fit the text based on last numberView
            if textLayoutManager.textViewportLayoutController.viewportRange != nil {
                let newGutterWidth = max(requiredWidthFitText, gutterView.minimumThickness)
                if !newGutterWidth.isAlmostEqual(to: gutterView.frame.size.width, tolerance: .ulpOfOne), newGutterWidth > gutterView.frame.size.width {
                    gutterView.frame.size.width = newGutterWidth
                }
            }
        }
    }

    private func layoutGutterMarkers() {
        guard let gutterView else {
            return
        }

        gutterView.layoutMarkers()
    }

    /// terminal patch: the zero-based line index of `location`, which the
    /// viewport layout guarantees is a paragraph start. Counts paragraph
    /// separators in the backing string — no per-line object materialization —
    /// and resumes from the previously numbered viewport start
    /// (`gutterLineIndexCache`) so a scroll only scans the text between the
    /// old and new positions.
    private func lineIndex(at location: NSTextLocation) -> Int {
        let documentStart = textLayoutManager.documentRange.location
        let offset = textContentManager.offset(from: documentStart, to: location)
        guard offset > 0 else {
            gutterLineIndexCache = (0, 0)
            return 0
        }
        // Every STTextView is storage-backed in practice; keep the original
        // element walk as the fallback for any exotic content manager.
        guard let backing = (textContentManager as? NSTextContentStorage)?.textStorage?.mutableString else {
            return textContentManager.textElements(
                for: NSTextRange(location: documentStart, end: location)!
            ).count
        }

        var (baseOffset, baseLine) = gutterLineIndexCache ?? (0, 0)
        if baseOffset < 0 || baseOffset > backing.length {
            // Defensive: a stale cache (missed invalidation) must degrade to a
            // full rescan, never to an out-of-bounds read.
            (baseOffset, baseLine) = (0, 0)
        }

        let line: Int
        if offset >= baseOffset {
            line = baseLine + Self.paragraphSeparatorCount(
                in: backing, range: NSRange(location: baseOffset, length: offset - baseOffset)
            )
        } else {
            line = baseLine - Self.paragraphSeparatorCount(
                in: backing, range: NSRange(location: offset, length: baseOffset - offset)
            )
        }
        gutterLineIndexCache = (offset, line)
        return line
    }

    /// Number of paragraph separators in `range`, matching the boundaries
    /// NSTextContentStorage splits paragraphs on: LF, CR, CRLF (one separator)
    /// and PS (U+2029). Deliberately *not* NEL (U+0085), LS (U+2028), VT or FF
    /// — `-[NSTextContentStorage textElements(for:)]` keeps those inside a
    /// paragraph, so counting them would number every line after one too high.
    /// Scans fixed-size chunks so large documents never materialize per-line
    /// objects or a full character copy at once.
    private static func paragraphSeparatorCount(in string: NSString, range: NSRange) -> Int {
        guard range.length > 0 else { return 0 }
        var count = 0
        var buffer = [unichar](repeating: 0, count: min(range.length, 64 * 1024))
        var location = range.location
        let end = range.location + range.length
        // Tracks a CR at a chunk's trailing edge so the LF opening the next
        // chunk is still recognized as the same CRLF separator.
        var previousWasCR = false
        while location < end {
            let chunkLength = min(buffer.count, end - location)
            buffer.withUnsafeMutableBufferPointer { pointer in
                string.getCharacters(pointer.baseAddress!, range: NSRange(location: location, length: chunkLength))
            }
            for index in 0..<chunkLength {
                switch buffer[index] {
                case 0x0A: // LF, already counted when it completes a CRLF
                    if !previousWasCR { count += 1 }
                    previousWasCR = false
                case 0x0D: // CR separates on its own; a following LF is skipped
                    count += 1
                    previousWasCR = true
                case 0x2029: // PS
                    count += 1
                    previousWasCR = false
                default:
                    previousWasCR = false
                }
            }
            location += chunkLength
        }
        return count
    }
}
