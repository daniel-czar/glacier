import OmniCore
import Testing

@Test func recallSheetSearchAndThinCascade() {
    let rows = [
        RecallCommand(category: "git", command: "git branch --show-current", label: "current branch"),
        RecallCommand(category: "git", command: "git log -1 --oneline", label: "last commit"),
        RecallCommand(category: "mac-process", command: "lsof -nP -iTCP -sTCP:LISTEN", label: "local listeners"),
    ]
    let empty = RecallMatcher.search("", in: rows)
    #expect(empty.sheet == rows)
    #expect(!empty.shouldGenerate)
    let branch = RecallMatcher.search("which branch am I on", in: rows)
    #expect(branch.sheet.first?.command == "git branch --show-current")
    #expect(branch.strongHit && !branch.shouldGenerate)
    let thin = RecallMatcher.search("what is listening on port 5500", in: rows)
    #expect(thin.shouldGenerate)
    let absent = RecallMatcher.search("undo last commit but keep changes", in: rows)
    #expect(absent.sheet.first?.label == "last commit")
    #expect(absent.shouldGenerate)
    let port = RecallMatcher.search("what’s listening on port 5500", in: rows)
    #expect(port.sheet.first?.label == "local listeners")
    #expect(port.shouldGenerate)
    let typo = RecallMatcher.search("current brnach", in: rows)
    #expect(typo.sheet.first?.label == "current branch")
    #expect(typo.strongHit)
    let kill = RecallCommand(category: "mac-process", command: "kill -9 <pid>", label: "force kill pid", destructive: true)
    let concretePID = RecallMatcher.search("force kill pid 5500", in: [kill])
    #expect(concretePID.sheet.first == kill)
    #expect(!concretePID.strongHit && concretePID.shouldGenerate)
}

@Test func acceptedIntentAliasAndDestructiveFlags() {
    let accepted = RecallCommand(category: "git", command: "git reset --soft HEAD~1", label: "undo commit", intentAliases: ["undo last commit but keep the changes"])
    #expect(RecallMatcher.search("undo last commit but keep the changes", in: [accepted]).strongHit)
    for command in ["rm -rf build", "git push --force origin main", "git reset --hard HEAD", "git clean -fd", "kill -9 42"] {
        #expect(RecallCommand.isConservativelyDestructive(command), "\(command)")
    }
    #expect(!RecallCommand.isConservativelyDestructive("git reset --soft HEAD~1"))
}
