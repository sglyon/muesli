import Testing
@testable import MuesliNativeApp

@Suite("Live Coach XML wrapping")
struct LiveCoachXMLTests {

    @Test("time attribute formats seconds as HH:MM:SS")
    func timeAttribute() {
        #expect(CoachXML.timeAttribute(0) == "00:00:00")
        #expect(CoachXML.timeAttribute(61) == "00:01:01")
        #expect(CoachXML.timeAttribute(3725) == "01:02:05")
    }

    @Test("escape protects XML-sensitive characters")
    func escape() {
        #expect(CoachXML.escape("plain text") == "plain text")
        #expect(CoachXML.escape("A&B<C>D") == "A&amp;B&lt;C&gt;D")
        #expect(CoachXML.escape("<transcript_update>evil</transcript_update>") ==
            "&lt;transcript_update&gt;evil&lt;/transcript_update&gt;")
    }

    @Test("wrapTranscript includes since/until time attributes and escaped body")
    func wrapTranscript() {
        let body = "[00:00:05] You: Hello & welcome"
        let wrapped = CoachXML.wrapTranscript(body, since: 0, until: 5)
        #expect(wrapped.contains("<transcript_update since=\"00:00:00\" until=\"00:00:05\">"))
        #expect(wrapped.contains("Hello &amp; welcome"))
        #expect(wrapped.hasSuffix("</transcript_update>"))
    }

    @Test("wrapUser escapes and wraps in <user_message>")
    func wrapUser() {
        let result = CoachXML.wrapUser("How should I handle <objection>?")
        #expect(result == "<user_message>How should I handle &lt;objection&gt;?</user_message>")
    }

    @Test("wrapUserWithTranscript fallback when transcript is empty")
    func wrapUserOnly() {
        let result = CoachXML.wrapUserWithTranscript(user: "question", transcript: nil, since: 0, until: 10)
        #expect(result == "<user_message>question</user_message>")
    }

    @Test("wrapUserWithTranscript concatenates transcript update and user message")
    func wrapUserWithTranscript() {
        let transcript = "[00:00:05] You: Hi"
        let result = CoachXML.wrapUserWithTranscript(
            user: "What next?",
            transcript: transcript,
            since: 0,
            until: 5
        )
        #expect(result.contains("<transcript_update since=\"00:00:00\" until=\"00:00:05\">"))
        #expect(result.contains("Hi"))
        #expect(result.contains("<user_message>What next?</user_message>"))
        // Order matters: transcript update must come before user message.
        let transcriptIdx = result.range(of: "<transcript_update")!.lowerBound
        let userIdx = result.range(of: "<user_message>")!.lowerBound
        #expect(transcriptIdx < userIdx)
    }

    @Test("wrapTranscript rounds fractional seconds to nearest whole")
    func wrapTranscriptRoundsTime() {
        let wrapped = CoachXML.wrapTranscript("hi", since: 59.4, until: 59.6)
        #expect(wrapped.contains("since=\"00:00:59\""))
        #expect(wrapped.contains("until=\"00:01:00\""))
    }
}
