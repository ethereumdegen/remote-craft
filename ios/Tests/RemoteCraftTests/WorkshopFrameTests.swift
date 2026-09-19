import XCTest

@testable import RemoteCraft

/// The agent's stream is bare `data: {json}` with no `event:` name, so every decision this
/// app makes about a turn comes out of these few lines. Each test below is a protocol fact
/// that has a plausible wrong answer.
final class WorkshopFrameTests: XCTestCase {
    func testKeepAliveCommentsAndBlanksAreSkipped() {
        XCTAssertNil(SSE.frame(":"))
        XCTAssertNil(SSE.frame(": keep-alive"))
        XCTAssertNil(SSE.frame(""))
        XCTAssertNil(SSE.frame("event: reply"))
    }

    func testUndecodablePayloadIsSkippedRatherThanFatal() {
        XCTAssertNil(SSE.frame("data: {not json"))
    }

    /// A frame kind this build has never heard of is a newer agent, not a broken one.
    func testUnknownKindDecodesInsteadOfFailing() {
        XCTAssertEqual(SSE.frame(#"data: {"kind":"telemetry","x":1}"#), .unknown("telemetry"))
    }

    /// The chat bubble is `reply.content`. `llm_completed` fires for every model call in a
    /// turn, including ones that only picked a tool, and rendering those would show the
    /// user the agent's internal monologue as an answer.
    func testReplyCarriesTheTextAndLLMCompletedCarriesNone() {
        XCTAssertEqual(SSE.frame(#"data: {"kind":"reply","content":"done, 3 files"}"#),
                       .reply(text: "done, 3 files", awaiting: false, options: []))
        XCTAssertEqual(SSE.frame(#"data: {"kind":"llm_completed","content":"ignored"}"#),
                       .llmCompleted)
    }

    func testAwaitingReplyCarriesItsOptions() {
        let line = #"data: {"kind":"reply","content":"which branch?","awaiting_reply":true,"options":["main","dev"]}"#

        XCTAssertEqual(SSE.frame(line),
                       .reply(text: "which branch?", awaiting: true, options: ["main", "dev"]))
    }

    /// Some producers label their options; both shapes have to become buttons.
    func testLabelledOptionsDecodeToTheSameChoices() {
        let line = #"data: {"kind":"reply","content":"?","awaiting_reply":true,"options":[{"label":"yes"},{"value":"no"}]}"#

        XCTAssertEqual(SSE.frame(line), .reply(text: "?", awaiting: true, options: ["yes", "no"]))
    }

    /// `done` is the only frame that ends a turn — not `reply`, which can be followed by
    /// more tool calls.
    func testOnlyDoneIsTerminal() {
        XCTAssertEqual(SSE.frame(#"data: {"kind":"done","status":"completed"}"#)?.isTerminal, true)
        XCTAssertEqual(SSE.frame(#"data: {"kind":"reply","content":"partial"}"#)?.isTerminal, false)
        XCTAssertEqual(SSE.frame(#"data: {"kind":"turn_started"}"#)?.isTerminal, false)
    }

    func testToolFramesKeepTheirCallIDSoCompletionUpdatesTheSameRow() {
        let started = SSE.frame(#"data: {"kind":"tool_started","tool_call_id":"t1","name":"bash","args":{"cmd":"ls"}}"#)
        let completed = SSE.frame(#"data: {"kind":"tool_completed","tool_call_id":"t1","name":"bash","duration_ms":12,"result":"ok"}"#)

        XCTAssertEqual(started, .toolStarted(id: "t1", name: "bash", detail: "cmd=ls"))
        XCTAssertEqual(completed, .toolCompleted(id: "t1", name: "bash", detail: "12ms · ok", failed: false))
    }

    func testErrorFrameKeepsCodeMessageAndRetryability() {
        let line = #"data: {"kind":"error","code":"rate_limit","message":"slow down","retryable":true}"#

        XCTAssertEqual(SSE.frame(line),
                       .failure(code: "rate_limit", message: "slow down", retryable: true))
    }

    func testPlanAcceptsBothStringsAndObjects() {
        XCTAssertEqual(SSE.frame(#"data: {"kind":"plan","steps":["read","patch"]}"#),
                       .plan(["read", "patch"]))
        XCTAssertEqual(SSE.frame(#"data: {"kind":"plan","steps":[{"title":"read"},{"title":"patch"}]}"#),
                       .plan(["read", "patch"]))
    }
}

/// The reducer's job is to know when the composer may be used again. Getting this wrong
/// either locks the user out of a finished chat or lets them type into a running turn.
@MainActor
final class AgentFoldTests: XCTestCase {
    func testTurnLocksTheComposerAndOnlyDoneUnlocksIt() {
        let store = AgentStore()

        store.apply(.turnStarted)
        XCTAssertTrue(store.busy)

        // A reply is not the end of a turn: the agent can answer and keep working.
        store.apply(.reply(text: "working on it", awaiting: false, options: []))
        XCTAssertTrue(store.busy)

        store.apply(.done(status: "completed"))
        XCTAssertFalse(store.busy)
    }

    func testReplyBecomesABubbleAndLLMCompletedDoesNot() {
        let store = AgentStore()

        store.apply(.llmCompleted)
        XCTAssertTrue(store.lines.isEmpty)

        store.apply(.reply(text: "here you go", awaiting: false, options: []))
        XCTAssertEqual(store.lines.map(\.text), ["here you go"])
    }

    /// A completed tool updates the row its start made, so a turn with ten tool calls is
    /// ten rows and not twenty.
    func testToolCompletionUpdatesTheRowItStarted() {
        let store = AgentStore()

        store.apply(.toolStarted(id: "t1", name: "bash", detail: "ls"))
        store.apply(.toolCompleted(id: "t1", name: "bash", detail: "8ms", failed: true))

        XCTAssertEqual(store.lines.count, 1)
        XCTAssertEqual(store.lines[0].role, .tool(running: false, failed: true))
        XCTAssertEqual(store.lines[0].detail, "8ms")
    }

    /// Options only stand while the agent is actually waiting; a later plain reply clears
    /// them, or the user is offered stale buttons for a question already answered.
    func testOptionsClearOnTheNextPlainReply() {
        let store = AgentStore()

        store.apply(.reply(text: "which?", awaiting: true, options: ["a", "b"]))
        XCTAssertEqual(store.options, ["a", "b"])

        store.apply(.reply(text: "ok", awaiting: false, options: []))
        XCTAssertTrue(store.options.isEmpty)
    }
}
