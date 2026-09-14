import Foundation
import XCTest
import UIKit
@testable import FarRelay

@MainActor
final class TerminalNativeAccessibilityTests: XCTestCase {
    func testNativeEditorBufferDoesNotRequestReplacementAcrossRepeatedTextMutations() {
        let buffer = TerminalNativeInputBuffer()
        let editorID = UUID()
        buffer.attach(editorID: editorID, initialText: "", writeNativeText: { _ in })
        buffer.nativeEditingDidBegin()

        for text in ["a", "ab", "abc", "abcdefghij"] {
            buffer.nativeTextDidChange(text)
            // Represents view updates caused by incoming output, Dynamic
            // Reading, and transcript changes while this editor remains live.
            buffer.attach(editorID: editorID, initialText: "", writeNativeText: { _ in })
            XCTAssertEqual(buffer.editorID, editorID)
            XCTAssertTrue(buffer.isEditing)
            XCTAssertEqual(buffer.editorReplacementCount, 0)
        }
    }

    func testNativeEditorBufferSeparatesEditingFromAccessibilityFocus() {
        let buffer = TerminalNativeInputBuffer()
        buffer.attach(editorID: UUID(), initialText: "", writeNativeText: { _ in })
        buffer.nativeEditingDidBegin()
        buffer.nativeAccessibilityFocusDidChange(false)

        XCTAssertTrue(buffer.isEditing)
        XCTAssertFalse(buffer.isAccessibilityFocused)

        buffer.nativeAccessibilityFocusDidChange(true)
        XCTAssertTrue(buffer.isEditing)
        XCTAssertTrue(buffer.isAccessibilityFocused)
    }

    func testNativeEditorBufferClearsTheSameNativeBufferAfterSuccessfulSubmission() {
        var writes: [String] = []
        let buffer = TerminalNativeInputBuffer()
        buffer.attach(editorID: UUID(), initialText: "", writeNativeText: { writes.append($0) })
        buffer.nativeTextDidChange("status")
        buffer.clear()

        XCTAssertEqual(buffer.currentText, "")
        XCTAssertEqual(writes, [""])
        XCTAssertEqual(buffer.editorReplacementCount, 0)
    }

    func testNativeBufferSurvivesOutputAndDynamicReadingThenPreservesFailedSubmission() async {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: TerminalPresentationFixtures.empty(revision: 0)
        )
        let model = TerminalPresentationModel(session: session)
        let buffer = TerminalNativeInputBuffer()
        let editorID = UUID()
        var nativeWrites: [String] = []
        buffer.attach(editorID: editorID, initialText: "", writeNativeText: { nativeWrites.append($0) })
        buffer.nativeEditingDidBegin()
        buffer.nativeTextDidChange("pwd")

        model.setDynamicReadingEnabled(true)
        _ = model.process(
            TerminalPresentationFixtures.output(revision: 1, lines: ["remote output"]),
            sessionState: .connected
        )
        buffer.attach(editorID: editorID, initialText: model.inputText, writeNativeText: { nativeWrites.append($0) })

        XCTAssertEqual(buffer.currentText, "pwd")
        XCTAssertEqual(buffer.editorID, editorID)
        XCTAssertTrue(buffer.isEditing)
        XCTAssertEqual(buffer.editorReplacementCount, 0)

        model.inputText = buffer.currentText
        await model.submitInput(buffer.currentText)
        if model.lastInputError == nil {
            buffer.clear()
        }
        XCTAssertEqual(model.inputText, "")
        XCTAssertEqual(buffer.currentText, "")
        XCTAssertEqual(nativeWrites, [""])

        buffer.nativeTextDidChange("git push")
        session.sendError = TerminalSendFailure()
        model.inputText = buffer.currentText
        await model.submitInput(buffer.currentText)
        if model.lastInputError == nil {
            buffer.clear()
        }

        XCTAssertEqual(model.inputText, "git push")
        XCTAssertEqual(buffer.currentText, "git push")
        XCTAssertEqual(nativeWrites, [""])
        XCTAssertEqual(buffer.editorID, editorID)
        XCTAssertTrue(buffer.isEditing)
    }

    func testNativeConversationRowExposesOneFlattenedAccessibilityElement() {
        let entry = AccessibleConversationEntry(
            text: "first line\r\nsecond line",
            role: .incomingContent
        )
        let view = TerminalConversationRowView()
        view.configure(
            entry: entry,
            accessibilityText: entry.accessibilityText,
            actions: [.copy, .openSnapshot],
            onAction: { _ in },
            onAccessibilityFocusChanged: { _ in }
        )

        XCTAssertTrue(view.isAccessibilityElement)
        XCTAssertFalse(view.accessibilityElementsHidden)
        XCTAssertFalse(view.subviews.first?.isAccessibilityElement ?? true)
        XCTAssertEqual(view.accessibilityLabel, "first line second line")
        XCTAssertFalse(view.accessibilityLabel?.contains("\n") == true)
        XCTAssertEqual(view.accessibilityCustomActions?.map(\.name), ["Copy", "Open Snapshot"])
    }
}
