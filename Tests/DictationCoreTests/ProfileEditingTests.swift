import Testing
@testable import DictationCore

@Suite struct ProfileEditingTests {
    @Test func aNewProfileGetsAFreeNameAndGoesBeforeGeneral() {
        var set = ProfileSet.defaults
        let first = set.addProfile()
        let second = set.addProfile()
        #expect(set.profiles[first].name == "New profile")
        #expect(set.profiles[second].name == "New profile 2")
        #expect(set.profiles.last?.name == "General")
        #expect(set.profiles[first].apps.isEmpty)
    }

    @Test func duplicatingCopiesTheSettingsButNotTheApps() {
        var set = ProfileSet.defaults
        let index = set.duplicateProfile(at: 0)
        #expect(set.profiles[index].name == "Coding copy")
        #expect(set.profiles[index].spokenSymbols == true)
        #expect(set.profiles[index].apps.isEmpty)
    }

    @Test func generalCannotBeRemoved() {
        var set = ProfileSet.defaults
        #expect(set.removeProfile(at: set.profiles.count - 1) == false)
        #expect(set.profiles.last?.name == "General")
        #expect(set.removeProfile(at: 0) == true)
        #expect(set.profiles.first?.name == "Notes")
    }

    @Test func anAppBelongsToOneProfileOnly() {
        var set = ProfileSet.defaults
        set.assign(app: "com.googlecode.iterm2", toProfileAt: 1)
        #expect(set.profiles[1].apps.contains("com.googlecode.iterm2"))
        #expect(!set.profiles[0].apps.contains("com.googlecode.iterm2"))
        #expect(set.profile(forApp: "com.googlecode.iterm2", override: nil).name == "Notes")
    }

    @Test func assigningAnAppTwiceKeepsOneEntry() {
        var set = ProfileSet.defaults
        set.assign(app: "com.example.app", toProfileAt: 1)
        set.assign(app: "com.example.app", toProfileAt: 1)
        #expect(set.profiles[1].apps.filter { $0 == "com.example.app" }.count == 1)
    }

    @Test func renamingAProfileFollowsInTheDictionary() {
        var set = ProfileSet.defaults
        var dictionary = UserDictionary.defaults
        set.rename(profileAt: 0, to: "Terminal", dictionary: &dictionary)
        #expect(set.profiles[0].name == "Terminal")
        #expect(dictionary.contextEntries(for: "Terminal").contains { $0.written == "~" })
    }

    @Test func aRenameToATakenOrEmptyNameIsRefused() {
        var set = ProfileSet.defaults
        var dictionary = UserDictionary.defaults
        set.rename(profileAt: 0, to: "Notes", dictionary: &dictionary)
        set.rename(profileAt: 0, to: "  ", dictionary: &dictionary)
        #expect(set.profiles[0].name == "Coding")
    }
}

@Suite struct CommaListTests {
    @Test func splitsOnCommasAndTrims() {
        #expect(CommaList.parse(" today, two ,, tilda ") == ["today", "two", "tilda"])
    }

    @Test func joinsWithCommas() {
        #expect(CommaList.format(["today", "two"]) == "today, two")
    }
}
