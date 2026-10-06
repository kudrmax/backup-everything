import BackupCore
import Foundation
import Testing
@testable import BackupEverything

/// A folder on an external disk is used only on the disk confirmed for it; how that looks and how it is confirmed.
@MainActor
struct DiskConfirmationTests {
    private let mine = DiskIdentity(uuid: "11111111-AAAA-4AAA-8AAA-111111111111", name: "TEST-BE-A")
    private let stranger = DiskIdentity(uuid: "22222222-BBBB-4BBB-8BBB-222222222222", name: "TEST-BE-B")

    // MARK: Presentation

    @Test func diskProblemOutweighsWhatTheReportSays() {
        let id = UUID()
        let report = StatusReport(items: [.connectDestination(destinationId: id)])
        #expect(DestinationCondition.of(id, report: report, unavailable: [id], disk: .otherDisk(stranger)) == .otherDisk(name: "TEST-BE-B"))
        #expect(DestinationCondition.of(id, report: report, unavailable: [id], disk: .notConfirmed(connected: nil)) == .diskNotConfirmed(connected: nil))
        #expect(DestinationCondition.of(id, report: report, unavailable: [], disk: .notConfirmed(connected: stranger)) == .diskNotConfirmed(connected: "TEST-BE-B"))
        #expect(DestinationCondition.of(id, report: report, unavailable: [], disk: .confirmed) == .needsConnection)
        #expect(DestinationCondition.of(id, report: StatusReport(items: []), unavailable: [], disk: .notNeeded) == .available)
        #expect(DestinationCondition.of(id, report: report, unavailable: [id], disk: .unidentified(name: "TEST-BE-C")) == .diskUnidentified(name: "TEST-BE-C"))
        let missing = MissingFolder(path: "/Volumes/TEST-BE-A/Backups", disk: "TEST-BE-A")
        #expect(DestinationCondition.of(id, report: report, unavailable: [id], disk: .confirmed, missingFolder: missing) == .folderMissing(missing))
        #expect(DestinationCondition.of(id, report: report, unavailable: [id], disk: .otherDisk(stranger), missingFolder: missing) == .otherDisk(name: "TEST-BE-B"))
    }

    @Test func diskWhoseIDCannotBeReadIsExplainedAndNotOfferedForConfirmation() {
        let unreadable = DestinationCondition.diskUnidentified(name: "TEST-BE-C")
        #expect(unreadable.problem == "can’t read the ID of disk “TEST-BE-C”")
        #expect(unreadable.explanation(destinationName: "HDD")
            == "Couldn’t read the ID of the connected disk “TEST-BE-C”, so it isn’t known whether it is the disk of “HDD”. Nothing is written to it or deleted from it. The app checks again on its own; if this goes on, reconnect the disk.")
        #expect(!unreadable.offersConfirmation)
        #expect(!unreadable.isConnected)
        #expect(unreadable.mark == "exclamationmark.triangle.fill")
        #expect(DiskTexts.copiesNote(unreadable) == "The disk’s ID can’t be read — copies aren’t shown.")
    }

    @Test func folderMissingOnAConnectedDiskIsToldAsSuch() {
        let onDisk = DestinationCondition.folderMissing(MissingFolder(path: "/Volumes/TEST-BE-A/Backups", disk: "TEST-BE-A"))
        #expect(onDisk.problem == "folder not found")
        #expect(onDisk.explanation(destinationName: "HDD")
            == "The folder “/Volumes/TEST-BE-A/Backups” doesn’t exist on the disk “TEST-BE-A”. The app doesn’t create it itself: create it or choose another folder.")
        #expect(DiskTexts.copiesNote(onDisk) == "The folder “/Volumes/TEST-BE-A/Backups” doesn’t exist on the disk “TEST-BE-A” — copies can’t be seen.")
        #expect(!onDisk.offersConfirmation)
        #expect(onDisk.mark == "exclamationmark.circle.fill")

        let onLaptop = DestinationCondition.folderMissing(MissingFolder(path: "~/Backups", disk: nil))
        #expect(onLaptop.explanation(destinationName: "Laptop")
            == "The folder “~/Backups” doesn’t exist. The app doesn’t create it itself: create it or choose another folder.")
        #expect(DiskTexts.copiesNote(onLaptop) == "The folder “~/Backups” doesn’t exist — copies can’t be seen.")
    }

    @Test func diskProblemsAreTextsInYellow() {
        let other = DestinationCondition.otherDisk(name: "TEST-BE-B")
        #expect(other.problem == "another disk named “TEST-BE-B” is connected")
        #expect(other.explanation(destinationName: "HDD")
            == "Another disk named “TEST-BE-B” is connected. Nothing is written to it or deleted from it. If it is the disk of “HDD”, press “This is my HDD”.")
        #expect(other.offersConfirmation)
        #expect(!other.isConnected)
        #expect(StatusStyle.color(.attention) == .orange)

        let unplugged = DestinationCondition.diskNotConfirmed(connected: nil)
        #expect(unplugged.problem == "disk not confirmed")
        #expect(unplugged.explanation(destinationName: "HDD")
            == "Confirm the disk for “HDD”: connect it and press “Read from connected disk” in its settings.")
        #expect(!unplugged.offersConfirmation)

        let plugged = DestinationCondition.diskNotConfirmed(connected: "TEST-BE-A")
        #expect(plugged.explanation(destinationName: "HDD")
            == "Confirm the disk for “HDD”: if the connected disk “TEST-BE-A” is it, press “This is my HDD”.")
        #expect(plugged.offersConfirmation)
        #expect(plugged.mark == "questionmark.circle.fill")
        #expect(other.mark == "exclamationmark.triangle.fill")
        #expect(DiskTexts.copiesNote(plugged) == "The disk isn’t confirmed — copies aren’t shown.")
        #expect(DestinationCondition.unreachable.problem == "unavailable")

        #expect(DestinationCondition.available.explanation(destinationName: "HDD") == nil)
        #expect(DestinationCondition.offline.explanation(destinationName: "HDD") == nil)
        #expect(DestinationCondition.confirmTitle("HDD") == "This is my HDD")
        #expect(DestinationLink.title(of: Destination(name: "HDD", kind: .localFolder(path: "/x")), used: nil, condition: other)
            == "HDD · another disk named “TEST-BE-B” is connected")
    }

    @Test func settingsShowTheRememberedDisk() {
        #expect(DiskTexts.name(nil) == "Not set")
        #expect(DiskTexts.id(nil) == nil)
        #expect(DiskTexts.name(mine) == "“TEST-BE-A”")
        #expect(DiskTexts.id(mine) == "ID 11111111-AAAA-4AAA-8AAA-111111111111")
        #expect(DiskTexts.id(DiskIdentity(uuid: nil, name: "TEST-BE-C")) == "the disk reports no ID")
        #expect(DiskTexts.copiesNote(.otherDisk(name: "TEST-BE-B")) == "Another disk is connected — its contents aren’t shown.")
        #expect(DiskTexts.copiesNote(.offline) == "Not connected — copies can’t be seen.")
    }

    @Test func menuListsADestinationOnAnotherDisk() {
        let hdd = Destination(name: "HDD", kind: .localFolder(path: "/x"), disk: mine)
        let lines = MenuLines.of(config: Config(destinations: [hdd]), state: AppState(), report: StatusReport(items: []), unavailable: [hdd.id], disks: [hdd.id: .otherDisk(stranger)])
        #expect(lines.map(\.text) == ["another disk named “TEST-BE-B” is connected"])
        #expect(lines.map(\.severity) == [.attention])
    }

    @Test func menuListsADestinationWhoseFolderIsMissing() {
        let hdd = Destination(name: "HDD", kind: .localFolder(path: "/x"), disk: mine)
        let lines = MenuLines.of(
            config: Config(destinations: [hdd]), state: AppState(), report: StatusReport(items: []), unavailable: [hdd.id],
            disks: [hdd.id: .confirmed], missingFolders: [hdd.id: MissingFolder(path: "/x", disk: "TEST-BE-A")]
        )
        #expect(lines.map(\.text) == ["folder not found"])
    }

    @Test func changingTheFolderForgetsTheDisk() {
        var draft = DestinationDraft(Destination(name: "HDD", kind: .localFolder(path: "/Volumes/TEST-BE-A/Backups"), disk: mine))
        #expect(draft.disk == mine)
        #expect(!draft.hasChanges)
        draft.path = "/Volumes/TEST-BE-A/Backups"
        #expect(draft.disk == mine)
        draft.path = "/Volumes/TEST-BE-B/Backups"
        #expect(draft.disk == nil)
        #expect(draft.build().disk == nil)
        draft.disk = stranger
        #expect(draft.build().disk == stranger)
        draft.typeChoice = .rclone
        #expect(draft.build().disk == nil)
    }

    @Test func diskConfirmedMeanwhileReachesTheOpenDraft() {
        let saved = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/TEST-BE-A/Backups"))
        var untouched = DestinationDraft(saved)
        untouched.diskConfirmed(mine)
        #expect(untouched.disk == mine)
        #expect(!untouched.hasChanges)

        var moved = DestinationDraft(saved)
        moved.path = "/Volumes/TEST-BE-B/Backups"
        moved.diskConfirmed(mine)
        #expect(moved.disk == nil)
        #expect(moved.hasChanges)
    }

    // MARK: Model

    @Test func unconfirmedDiskGetsNothingUntilThePersonConfirmsIt() async throws {
        let disks = FakeDisks(.connected(mine))
        let fixture = try ModelFixture(disks: disks)
        let hdd = try fixture.disk("HDD")
        let notes = try fixture.folderSource(to: [hdd])
        try await fixture.use(Config(sources: [notes], destinations: [hdd]))
        let model = fixture.model

        #expect(await eventually { model.condition(of: hdd) == .diskNotConfirmed(connected: "TEST-BE-A") })
        await model.runNow(notes)
        #expect(await model.copies(in: hdd) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path(of: hdd)).isEmpty)
        #expect(try fixture.savedConfig().destinations.map(\.disk) == [nil], "nothing is confirmed by itself")

        let confirmed = try #require(await model.confirmConnectedDisk(for: hdd))
        #expect(confirmed.disk == mine)
        #expect(try fixture.savedConfig().destination(hdd.id)?.disk == mine)
        #expect(await eventually { model.condition(of: hdd) == .available })
        await model.runNow(notes)
        #expect(await model.copies(in: confirmed)?[notes.id]?.count == 1)
    }

    @Test func anotherDiskWithTheSameNameIsNotUsedUntilConfirmed() async throws {
        let disks = FakeDisks(.connected(mine))
        let fixture = try ModelFixture(disks: disks)
        var hdd = try fixture.disk("HDD")
        hdd.disk = mine
        let notes = try fixture.folderSource(to: [hdd])
        try await fixture.use(Config(sources: [notes], destinations: [hdd]))
        let model = fixture.model
        await model.runNow(notes)
        #expect(await model.copies(in: hdd)?[notes.id]?.count == 1)

        disks.location = .connected(stranger)
        await model.refresh()
        #expect(await eventually { model.condition(of: hdd) == .otherDisk(name: "TEST-BE-B") })
        #expect(await !model.isAvailable(hdd))
        #expect(await model.copies(in: hdd) == nil)
        #expect(await model.usedBytes(hdd) == nil)
        #expect(await model.snapshots(of: notes, in: hdd).isEmpty)
        #expect(DestinationDetails.text(of: hdd, model: model).hasPrefix("Another disk named “TEST-BE-B” is connected."))

        #expect(try #require(await model.confirmConnectedDisk(for: hdd)).disk == stranger)
        #expect(try fixture.savedConfig().destination(hdd.id)?.disk == stranger)
        #expect(await eventually { model.condition(of: hdd) == .available })
    }

    @Test func diskThatReportsNoIdentityCanStillBeConfirmed() async throws {
        let unreadable = DiskIdentity(uuid: nil, name: "TEST-BE-C")
        let disks = FakeDisks(.connected(unreadable))
        let fixture = try ModelFixture(disks: disks)
        var hdd = try fixture.disk("HDD")
        hdd.disk = mine
        try await fixture.use(Config(destinations: [hdd]))
        let model = fixture.model
        #expect(await eventually { model.condition(of: hdd) == .otherDisk(name: "TEST-BE-C") })

        #expect(try #require(await model.confirmConnectedDisk(for: hdd)).disk == unreadable)
        #expect(await eventually { model.condition(of: hdd) == .available })
    }

    @Test func nothingIsConfirmedWithoutAConnectedDisk() async throws {
        let fixture = try ModelFixture(disks: FakeDisks(.notConnected))
        let hdd = try fixture.disk("HDD")
        try await fixture.use(Config(destinations: [hdd]))
        #expect(await eventually { fixture.model.condition(of: hdd) == .diskNotConfirmed(connected: nil) })
        #expect(await fixture.model.confirmConnectedDisk(for: hdd) == nil)
        #expect(try fixture.savedConfig().destination(hdd.id)?.disk == nil)
    }

    @Test func confirmationThatCannotBeWrittenIsReportedAndNothingChanges() async throws {
        let fixture = try ModelFixture(disks: FakeDisks(.connected(stranger)))
        var hdd = try fixture.disk("HDD")
        hdd.disk = mine
        try await fixture.use(Config(destinations: [hdd]))
        let damaged = Data("{ damaged".utf8)
        try damaged.write(to: fixture.store.configURL)

        #expect(await fixture.model.confirmConnectedDisk(for: hdd) == nil)
        #expect(fixture.model.problem != nil)
        #expect(try Data(contentsOf: fixture.store.configURL) == damaged)
    }

    @Test func folderOnTheSystemDiskNeedsNoConfirmation() async throws {
        let fixture = try ModelFixture(disks: FakeDisks(.systemDisk))
        let hdd = try fixture.disk("HDD")
        try await fixture.use(Config(destinations: [hdd]))
        #expect(await eventually { fixture.model.diskChecks[hdd.id] == .notNeeded })
        #expect(fixture.model.condition(of: hdd) == .available)
        #expect(await fixture.model.confirmConnectedDisk(for: hdd) == nil)
    }

    @Test func removedDestinationTakesItsDiskAlong() async throws {
        let fixture = try ModelFixture(disks: FakeDisks(.connected(mine)))
        var hdd = try fixture.disk("HDD")
        hdd.disk = mine
        try await fixture.use(Config(destinations: [hdd]))
        #expect(await fixture.model.delete(hdd))
        let json = try String(contentsOf: fixture.store.configURL, encoding: .utf8)
        #expect(!json.contains(try #require(mine.uuid)))
    }

    @Test func diskWhoseIDCannotBeReadIsNotUsedAndNotConfirmed() async throws {
        let disks = FakeDisks(.unidentified(name: "TEST-BE-C"))
        let fixture = try ModelFixture(disks: disks)
        var hdd = try fixture.disk("HDD")
        hdd.disk = DiskIdentity(uuid: nil, name: "TEST-BE-C")
        let notes = try fixture.folderSource(to: [hdd])
        try await fixture.use(Config(sources: [notes], destinations: [hdd]))
        let model = fixture.model

        #expect(await eventually { model.condition(of: hdd) == .diskUnidentified(name: "TEST-BE-C") })
        await model.runNow(notes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path(of: hdd)).isEmpty, "a disk that could not be read is not taken for one without an ID")
        #expect(await model.confirmConnectedDisk(for: hdd) == nil)
        #expect(model.problem == "Could not read the ID of the disk “TEST-BE-C”. Nothing was remembered: reconnect the disk and try again.")
        #expect(try fixture.savedConfig().destination(hdd.id)?.disk == hdd.disk)

        disks.location = .connected(DiskIdentity(uuid: nil, name: "TEST-BE-C"))
        await model.refresh()
        #expect(await eventually { model.condition(of: hdd) == .available }, "read again at the next check")
    }

    @Test func readButtonTakesOnlyADiskWhoseIDWasRead() async throws {
        let disks = FakeDisks(.connected(mine))
        let fixture = try ModelFixture(disks: disks)
        let model = fixture.model
        #expect(model.readConnectedDisk(atFolder: "/Volumes/TEST-BE-A/Backups") == mine)
        #expect(model.problem == nil)

        disks.location = .unidentified(name: "TEST-BE-A")
        #expect(model.readConnectedDisk(atFolder: "/Volumes/TEST-BE-A/Backups") == nil)
        #expect(model.problem == "Could not read the ID of the disk “TEST-BE-A”. Nothing was remembered: reconnect the disk and try again.")

        model.dismissProblem()
        disks.location = .notConnected
        #expect(model.readConnectedDisk(atFolder: "/Volumes/TEST-BE-A/Backups") == nil)
        #expect(model.problem == nil)
    }

    @Test func confirmedDiskWithoutTheFolderSaysSo() async throws {
        let fixture = try ModelFixture(disks: FakeDisks(.connected(mine)))
        var hdd = try fixture.disk("HDD", connected: false)
        hdd.disk = mine
        let laptop = try fixture.disk("Laptop", connected: false)
        try await fixture.use(Config(destinations: [hdd, laptop]))
        let model = fixture.model

        #expect(await eventually { model.condition(of: hdd) == .folderMissing(MissingFolder(path: path(of: hdd), disk: "TEST-BE-A")) })
        #expect(DiskTexts.copiesNote(model.condition(of: hdd)).hasPrefix("The folder “\(path(of: hdd))” doesn’t exist on the disk “TEST-BE-A”"))
        #expect(model.condition(of: laptop) == .diskNotConfirmed(connected: "TEST-BE-A"))

        try FileManager.default.createDirectory(atPath: path(of: hdd), withIntermediateDirectories: true)
        await model.refresh()
        #expect(await eventually { model.condition(of: hdd) == .available })
    }

    @Test func folderMissingOnTheSystemDiskNamesNoDisk() async throws {
        let fixture = try ModelFixture(disks: FakeDisks(.systemDisk))
        let laptop = try fixture.disk("Laptop", connected: false)
        try await fixture.use(Config(destinations: [laptop]))
        #expect(await eventually { fixture.model.condition(of: laptop) == .folderMissing(MissingFolder(path: path(of: laptop), disk: nil)) })
    }

    @Test func copyOpensOnlyOnTheConfirmedDisk() async throws {
        let disks = FakeDisks(.connected(mine))
        let fixture = try ModelFixture(disks: disks)
        var hdd = try fixture.disk("HDD")
        hdd.disk = mine
        let notes = try fixture.folderSource(to: [hdd])
        try await fixture.use(Config(sources: [notes], destinations: [hdd]))
        let model = fixture.model
        await model.runNow(notes)
        #expect(await eventually { model.diskChecks[hdd.id] == .confirmed })
        let place = try #require(SourceLinks.copies(of: notes, config: model.config, state: model.state, disks: model.diskChecks).first)
        #expect(place.unavailableReason == nil)
        await model.openCopy(CopyPlace(destination: hdd, folder: nil, unavailableReason: "No copies yet"))
        #expect(fixture.finder.opened.isEmpty)

        disks.location = .connected(stranger)
        await model.openCopy(place)
        #expect(fixture.finder.opened.isEmpty, "the folder of the same path on another disk is not opened")
        #expect(model.problem == "Can’t open the copy in “HDD”: another disk is connected.")

        model.dismissProblem()
        disks.location = .connected(mine)
        await model.openCopy(place)
        #expect(fixture.finder.opened == [try #require(place.folder)])
        #expect(model.problem == nil)
    }

    private func path(of destination: Destination) -> String {
        guard case let .localFolder(path) = destination.kind else { return "" }
        return path
    }
}
