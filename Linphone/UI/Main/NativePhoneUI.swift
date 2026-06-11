/*
 * Astradial native phone UI.
 *
 * Replaces Linphone's ContentView with a UI matching the stock iOS
 * Phone app: Favourites / Recents / Contacts / Keypad / Voicemail.
 * Engine wiring (calls, history) goes through the existing Linphone
 * view models and TelecomManager; contacts come from CNContactStore.
 */

import SwiftUI
import linphonesw
import Contacts
import ContactsUI
import AVFoundation

// MARK: - SDK compatibility shims
// linphone-sdk stable >= 5.5.2 removed these members; the Linphone
// screens using them are hidden in Astradial but still compile.

extension Friend {
	var isReadOnly: Bool { !inList() }
}

extension FriendList {
	var isReadOnly: Bool { false }
}

extension ChatRoom {
	// Document/media listing APIs removed upstream; chat UI is hidden in Astradial.
	var documentContentsSize: Int { 0 }
	func getDocumentContentsRange(begin: Int, end: Int) -> [Content] { [] }
	var mediaContentsSize: Int { 0 }
	func getMediaContentsRange(begin: Int, end: Int) -> [Content] { [] }
	// Editing/composing additions from the beta SDK, absent in stable.
	func createReplacesMessage(message: ChatMessage) throws -> ChatMessage { try createEmptyMessage() }
	func stopComposing() {}
	func composeTextMessage() {}
	func retractMessage(message: ChatMessage) {}
}

extension Core {
	// Chat file-management settings from the beta SDK, absent in stable.
	var chatMessageFilesDirectories: [String] {
		get { [] }
		set {}
	}
	var chatMessageFilesDeletionEnabled: Bool {
		get { false }
		set {}
	}
}

extension ChatMessage {
	// Message editing/retraction feature not present in the stable SDK.
	var isRetracted: Bool { false }
	var isEditable: Bool { false }
	var isRetractable: Bool { false }
	var isEdited: Bool { false }
	var eventLog: EventLog? { nil }
}

// MARK: - Dialing helper

enum AstradialDialer {
	static func call(_ number: String) {
		let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		CoreContext.shared.doOnCoreQueue { core in
			if let address = core.interpretUrl(url: trimmed, applyInternationalPrefix: LinphoneUtils.applyInternationalPrefix(core: core)) {
				TelecomManager.shared.doCallOrJoinConf(address: address)
			}
		}
	}
}

// MARK: - Root tab view

struct NativePhoneRootView: View {
	@ObservedObject private var telecomManager = TelecomManager.shared
	@ObservedObject private var ticketsViewModel = TicketsViewModel.shared
	@StateObject private var callViewModel = CallViewModel()

	@State private var selectedTab: Int = {
		if let env = ProcessInfo.processInfo.environment["DEFAULT_TAB"], let tab = Int(env) { return tab }
		// Owners who signed in during onboarding land on Analytics.
		return UserDefaults.standard.object(forKey: "astradial_initial_tab") as? Int ?? 3
	}()

	var body: some View {
		ZStack {
			TabView(selection: $selectedTab) {
				AnalyticsTabView()
					.tabItem { Label("Analytics", systemImage: "waveform.path.ecg") }
					.tag(0)
				RecentsTabView()
					.tabItem { Label("Recents", systemImage: "clock.fill") }
					.tag(1)
				ContactsTabView()
					.tabItem { Label("Contacts", systemImage: "person.crop.circle.fill") }
					.tag(2)
				KeypadTabView()
					.tabItem { Label("Keypad", systemImage: "circle.grid.3x3.fill") }
					.tag(3)
				TicketsTabView()
					.tabItem { Label("Tickets", systemImage: "phone.arrow.down.left.fill") }
					.badge(ticketsViewModel.openCount)
					.tag(4)
			}
			.task { await TicketsViewModel.shared.reload() }

			if telecomManager.callDisplayed
				&& ((telecomManager.callInProgress && telecomManager.outgoingCallStarted) || telecomManager.callConnected)
				&& !telecomManager.meetingWaitingRoomDisplayed {
				NativeCallView()
					.environmentObject(callViewModel)
				.zIndex(5)
				.transition(.scale.combined(with: .move(edge: .top)))
				.onAppear {
					UIApplication.shared.isIdleTimerDisabled = true
					callViewModel.resetCallView()
				}
				.onDisappear {
					UIApplication.shared.isIdleTimerDisabled = false
				}
			}

			ToastView()
				.zIndex(6)
		}
	}
}

// MARK: - Shared avatar

struct InitialsAvatar: View {
	let name: String
	var size: CGFloat = 44

	var body: some View {
		ZStack {
			Circle().fill(
				LinearGradient(
					colors: [Color(red: 0.64, green: 0.69, blue: 0.86), Color(red: 0.44, green: 0.50, blue: 0.72)],
					startPoint: .top, endPoint: .bottom
				)
			)
			if initials.isEmpty {
				Image(systemName: "person.fill")
					.font(.system(size: size * 0.5))
					.foregroundStyle(.white)
			} else {
				Text(initials)
					.font(.system(size: size * 0.42, weight: .medium))
					.foregroundStyle(.white)
			}
		}
		.frame(width: size, height: size)
	}

	private var initials: String {
		let parts = name.split(separator: " ").prefix(2)
		let letters = parts.compactMap { $0.first.map(String.init) }
		// Numbers get the generic silhouette, not digit initials.
		if name.first?.isNumber == true || name.hasPrefix("+") { return "" }
		return letters.joined().uppercased()
	}
}

// MARK: - Keypad

struct KeypadTabView: View {
	@State private var number = ""
	@State private var accountInitial = ""

	private let keys: [[(digit: String, letters: String)]] = [
		[("1", " "), ("2", "ABC"), ("3", "DEF")],
		[("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
		[("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
		[("*", ""), ("0", "+"), ("#", "")]
	]

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				accountChip
				Spacer()
			}
			.padding(.horizontal, 20)
			.padding(.top, 8)

			Spacer()

			numberDisplay
				.padding(.horizontal, 40)
				.padding(.bottom, 18)

			VStack(spacing: 14) {
				ForEach(0..<4, id: \.self) { row in
					HStack(spacing: 26) {
						ForEach(keys[row], id: \.digit) { key in
							KeypadButton(digit: key.digit, letters: key.letters) {
								tap(key.digit)
							} onLongPress: {
								if key.digit == "0" {
									if !number.isEmpty { number.removeLast() }
									number.append("+")
									haptic()
								}
							}
						}
					}
				}
			}

			callButton
				.padding(.top, 16)
				.padding(.bottom, 12)
		}
		.onAppear(perform: loadAccountInitial)
	}

	private var accountChip: some View {
		HStack(spacing: 4) {
			RoundedRectangle(cornerRadius: 8, style: .continuous)
				.fill(Color.accentColor)
				.frame(width: 32, height: 32)
				.overlay(
					Text(accountInitial.isEmpty ? "A" : accountInitial)
						.font(.system(size: 18, weight: .semibold))
						.foregroundStyle(.white)
				)
			VStack(spacing: 0) {
				Image(systemName: "chevron.up")
				Image(systemName: "chevron.down")
			}
			.font(.system(size: 9, weight: .bold))
			.foregroundStyle(.secondary)
		}
	}

	private var numberDisplay: some View {
		HStack {
			Text(number)
				.font(.system(size: 40, weight: .regular))
				.lineLimit(1)
				.minimumScaleFactor(0.4)
				.frame(maxWidth: .infinity)
				.contentTransition(.numericText())
			if !number.isEmpty {
				Button {
					if !number.isEmpty { number.removeLast() }
					haptic()
				} label: {
					Image(systemName: "delete.backward")
						.font(.system(size: 24))
						.foregroundStyle(.secondary)
				}
				.onLongPressGesture { number = "" }
			}
		}
		.frame(height: 50)
	}

	private var callButton: some View {
		Button {
			if number.isEmpty {
				recallLastDialled()
			} else {
				AstradialDialer.call(number)
			}
		} label: {
			Circle()
				.fill(Color.green)
				.frame(width: 72, height: 72)
				.overlay(
					Image(systemName: "phone.fill")
						.font(.system(size: 30, weight: .medium))
						.foregroundStyle(.white)
				)
		}
		.buttonStyle(.plain)
	}

	private func tap(_ digit: String) {
		number.append(digit)
		haptic()
		AudioServicesPlaySystemSound(1104)
	}

	private func haptic() {
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
	}

	private func recallLastDialled() {
		CoreContext.shared.doOnCoreQueue { core in
			if let last = core.callLogs.first(where: { $0.dir == .Outgoing }),
			   let username = last.remoteAddress?.username {
				DispatchQueue.main.async { number = username }
			}
		}
	}

	private func loadAccountInitial() {
		CoreContext.shared.doOnCoreQueue { core in
			let name = core.defaultAccount?.params?.identityAddress?.displayName
				?? core.defaultAccount?.params?.identityAddress?.username ?? ""
			DispatchQueue.main.async {
				accountInitial = name.first.map { String($0).uppercased() } ?? ""
			}
		}
	}
}

struct KeypadButton: View {
	let digit: String
	let letters: String
	let action: () -> Void
	var onLongPress: () -> Void = {}

	var body: some View {
		Button(action: action) {
			ZStack {
				Circle().fill(Color(.systemGray5))
				VStack(spacing: 0) {
					Text(digit)
						.font(.system(size: 36, weight: .regular))
						.foregroundStyle(.primary)
					if !letters.isEmpty {
						Text(letters)
							.font(.system(size: 10, weight: .semibold))
							.kerning(1.5)
							.foregroundStyle(letters == "+" ? .secondary : .primary)
					}
				}
				.offset(y: letters.isEmpty ? 0 : 2)
			}
			.frame(width: 82, height: 82)
		}
		.buttonStyle(.plain)
		.simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in onLongPress() })
	}
}

// MARK: - Recents

struct RecentsTabView: View {
	@StateObject private var viewModel = HistoryListViewModel()
	@State private var filter: RecentsFilter = .all
	@State private var scope: RecentsScope = .device
	@State private var searchText = ""
	@State private var companyCalls: [CDRCall] = []
	@State private var companyLoaded = false

	enum RecentsFilter: String, CaseIterable {
		case all = "All"
		case missed = "Missed"
	}

	enum RecentsScope: String, CaseIterable {
		case device = "This iPhone"
		case company = "Company"
	}

	var body: some View {
		NavigationStack {
			Group {
				if scope == .company {
					companyList
				} else {
					deviceList
				}
			}
			.navigationTitle("Recents")
			.searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					if scope == .device { EditButton() }
				}
				ToolbarItem(placement: .principal) {
					Picker("Filter", selection: $filter) {
						ForEach(RecentsFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
					}
					.pickerStyle(.segmented)
					.frame(width: 170)
				}
				ToolbarItem(placement: .topBarTrailing) {
					Menu {
						Picker("Show", selection: $scope) {
							Label("This iPhone", systemImage: "iphone").tag(RecentsScope.device)
							Label("Company", systemImage: "building.2").tag(RecentsScope.company)
						}
						if scope == .device {
							Button(role: .destructive) {
								viewModel.callLogsAddressToDelete = ""
								viewModel.removeCallLogs()
							} label: {
								Label("Clear All Recents", systemImage: "trash")
							}
						}
					} label: {
						Image(systemName: "line.3.horizontal.decrease")
					}
				}
			}
			.onChange(of: scope) { _, newScope in
				if newScope == .company && companyCalls.isEmpty {
					Task { await loadCompany() }
				}
			}
		}
	}

	private var deviceList: some View {
		List {
			ForEach(groupedLogs) { group in
				RecentsRow(group: group)
					.contentShape(Rectangle())
					.onTapGesture { AstradialDialer.call(group.latest.address) }
			}
			.onDelete(perform: delete)
		}
		.listStyle(.plain)
		.overlay {
			if groupedLogs.isEmpty {
				ContentUnavailableView(
					filter == .missed ? "No Missed Calls" : "No Calls on This iPhone",
					systemImage: "phone.arrow.up.right",
					description: Text("Calls you make or receive on this device appear here. Use the filter menu to see all company calls.")
				)
			}
		}
	}

	private var companyList: some View {
		List(filteredCompany) { call in
			CompanyCallRow(call: call)
		}
		.listStyle(.plain)
		.refreshable { await loadCompany() }
		.overlay {
			if filteredCompany.isEmpty {
				ContentUnavailableView(
					companyLoaded ? "No Company Calls" : "Loading…",
					systemImage: "building.2"
				)
			}
		}
	}

	private var filteredCompany: [CDRCall] {
		var calls = companyCalls
		if filter == .missed { calls = calls.filter(\.isMissed) }
		if !searchText.isEmpty {
			calls = calls.filter {
				($0.src ?? "").localizedCaseInsensitiveContains(searchText)
					|| ($0.dst ?? "").localizedCaseInsensitiveContains(searchText)
			}
		}
		return calls
	}

	private func loadCompany() async {
		let from = Calendar.current.date(byAdding: .day, value: -3, to: .now)!
		let fetched = (try? await AstradialAPI.shared.fetchCalls(from: from, to: .now, maxRecords: 600)) ?? []
		companyCalls = PulseViewModel.dedupSessions(fetched).sorted { $0.date > $1.date }
		companyLoaded = true
	}

	private var filteredLogs: [HistoryModel] {
		var logs = viewModel.callLogs
		if filter == .missed {
			logs = logs.filter { $0.status == Call.Status.Missed && !$0.isOutgoing }
		}
		if !searchText.isEmpty {
			logs = logs.filter {
				$0.addressName.localizedCaseInsensitiveContains(searchText)
					|| $0.address.localizedCaseInsensitiveContains(searchText)
			}
		}
		return logs
	}

	// Collapse consecutive calls with the same correspondent + direction + missed-ness.
	private var groupedLogs: [RecentsGroup] {
		var groups: [RecentsGroup] = []
		for log in filteredLogs {
			if let last = groups.last,
			   last.latest.address == log.address,
			   last.latest.isOutgoing == log.isOutgoing,
			   (last.latest.status == Call.Status.Missed) == (log.status == Call.Status.Missed) {
				groups[groups.count - 1].logs.append(log)
			} else {
				groups.append(RecentsGroup(logs: [log]))
			}
		}
		return groups
	}

	private func delete(at offsets: IndexSet) {
		for index in offsets {
			groupedLogs[index].logs.forEach { viewModel.removeCallLog(historyModel: $0) }
		}
	}
}

struct CompanyCallRow: View {
	let call: CDRCall
	@State private var player: AVPlayer?
	@State private var playing = false

	var body: some View {
		HStack(spacing: 12) {
			InitialsAvatar(name: call.src ?? "?", size: 44)
			VStack(alignment: .leading, spacing: 2) {
				Text(call.src ?? "Unknown")
					.font(.body.weight(.semibold))
					.foregroundStyle(call.isMissed ? Color.red : Color.primary)
					.lineLimit(1)
				HStack(spacing: 4) {
					Image(systemName: call.direction == "outbound" ? "arrow.up.right" : "arrow.down.left")
						.font(.caption2.weight(.bold))
					Text(call.queueName ?? (call.answeredBy.map { "ext \($0)" } ?? "company"))
						.font(.subheadline)
						.lineLimit(1)
				}
				.foregroundStyle(.secondary)
			}
			Spacer()
			Text(relativeDate(time_t(call.date.timeIntervalSince1970)))
				.font(.subheadline)
				.foregroundStyle(.secondary)
			if call.recordingUrl != nil {
				Button {
					togglePlayback()
				} label: {
					Image(systemName: playing ? "stop.circle.fill" : "play.circle")
						.font(.system(size: 22))
						.foregroundStyle(Color.accentColor)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.vertical, 2)
	}

	private func togglePlayback() {
		if playing {
			player?.pause()
			playing = false
			return
		}
		guard let path = call.recordingUrl,
			  let url = URL(string: path.hasPrefix("http") ? path : AstradialAPIConfig.base + path) else { return }
		Task {
			guard let token = try? await PlatformAuth.shared.bearerToken() else { return }
			let asset = AVURLAsset(url: url, options: [
				"AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]
			])
			player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
			player?.play()
			playing = true
		}
	}
}

struct RecentsGroup: Identifiable {
	var logs: [HistoryModel]
	var id: String { latest.callLogId }
	var latest: HistoryModel { logs[0] }
}

struct RecentsRow: View {
	let group: RecentsGroup

	private var isMissed: Bool {
		group.latest.status == Call.Status.Missed && !group.latest.isOutgoing
	}

	var body: some View {
		HStack(spacing: 12) {
			InitialsAvatar(name: group.latest.addressName, size: 44)

			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.body.weight(.semibold))
					.foregroundStyle(isMissed ? Color.red : Color.primary)
					.lineLimit(1)
				HStack(spacing: 4) {
					Image(systemName: group.latest.isOutgoing ? "arrow.up.right" : "arrow.down.left")
						.font(.caption2.weight(.bold))
					Text("phone")
						.font(.subheadline)
				}
				.foregroundStyle(.secondary)
			}

			Spacer()

			Text(relativeDate(group.latest.startDate))
				.font(.subheadline)
				.foregroundStyle(.secondary)

			NavigationLink {
				RecentsDetailView(group: group)
			} label: {
				EmptyView()
			}
			.frame(width: 28)
			.overlay(
				Image(systemName: "info.circle")
					.font(.system(size: 22))
					.foregroundStyle(Color.accentColor)
			)
		}
		.padding(.vertical, 2)
	}

	private var title: String {
		let name = group.latest.addressName
		return group.logs.count > 1 ? "\(name) (\(group.logs.count))" : name
	}
}

func relativeDate(_ start: time_t) -> String {
	let date = Date(timeIntervalSince1970: TimeInterval(start))
	if Calendar.current.isDateInToday(date) {
		return date.formatted(date: .omitted, time: .shortened)
	}
	if Calendar.current.isDateInYesterday(date) {
		return "Yesterday"
	}
	if let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now), date > weekAgo {
		return date.formatted(.dateTime.weekday(.wide))
	}
	return date.formatted(date: .numeric, time: .omitted)
}

struct RecentsDetailView: View {
	let group: RecentsGroup

	var body: some View {
		List {
			Section {
				HStack(spacing: 14) {
					InitialsAvatar(name: group.latest.addressName, size: 60)
					VStack(alignment: .leading) {
						Text(group.latest.addressName).font(.title3.weight(.semibold))
						Text(group.latest.address).font(.footnote).foregroundStyle(.secondary)
					}
				}
				Button {
					AstradialDialer.call(group.latest.address)
				} label: {
					Label("Call", systemImage: "phone.fill")
				}
			}
			Section("Calls") {
				ForEach(group.logs, id: \.callLogId) { log in
					HStack {
						Image(systemName: log.isOutgoing ? "arrow.up.right" : "arrow.down.left")
							.foregroundStyle(log.status == Call.Status.Missed ? .red : .secondary)
						VStack(alignment: .leading) {
							Text(log.isOutgoing ? "Outgoing Call" : (log.status == Call.Status.Missed ? "Missed Call" : "Incoming Call"))
							Text(Date(timeIntervalSince1970: TimeInterval(log.startDate)), style: .time)
								.font(.footnote).foregroundStyle(.secondary)
						}
						Spacer()
						if log.duration > 0 {
							Text(Duration.seconds(log.duration).formatted(.time(pattern: .minuteSecond)))
								.font(.footnote).foregroundStyle(.secondary)
						}
					}
				}
			}
		}
		.navigationBarTitleDisplayMode(.inline)
	}
}

// MARK: - Contacts

struct DeviceContact: Identifiable {
	let id: String
	let givenName: String
	let familyName: String
	let organization: String
	let thumbnail: Data?
	let numbers: [(label: String, value: String)]

	var displayName: String {
		let full = "\(givenName) \(familyName)".trimmingCharacters(in: .whitespaces)
		return full.isEmpty ? organization : full
	}

	var sortKey: String {
		let key = familyName.isEmpty ? (givenName.isEmpty ? organization : givenName) : familyName
		return key.isEmpty ? "#" : key
	}

	var sectionLetter: String {
		let letter = String(sortKey.prefix(1)).uppercased()
		return letter.first?.isLetter == true ? letter : "#"
	}
}

final class DeviceContactsModel: ObservableObject {
	@Published var contacts: [DeviceContact] = []
	@Published var accessDenied = false

	func load() {
		let store = CNContactStore()
		store.requestAccess(for: .contacts) { granted, _ in
			guard granted else {
				DispatchQueue.main.async { self.accessDenied = true }
				return
			}
			DispatchQueue.global(qos: .userInitiated).async {
				let keys: [CNKeyDescriptor] = [
					CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
					CNContactPhoneNumbersKey, CNContactThumbnailImageDataKey
				] as [CNKeyDescriptor]
				let request = CNContactFetchRequest(keysToFetch: keys)
				request.sortOrder = .userDefault
				var result: [DeviceContact] = []
				try? store.enumerateContacts(with: request) { contact, _ in
					result.append(DeviceContact(
						id: contact.identifier,
						givenName: contact.givenName,
						familyName: contact.familyName,
						organization: contact.organizationName,
						thumbnail: contact.thumbnailImageData,
						numbers: contact.phoneNumbers.map {
							(CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? CNLabelPhoneNumberMobile),
							 $0.value.stringValue)
						}
					))
				}
				DispatchQueue.main.async { self.contacts = result }
			}
		}
	}
}

struct ContactsTabView: View {
	@StateObject private var model = DeviceContactsModel()
	@State private var searchText = ""
	@State private var showNewContact = false

	var body: some View {
		NavigationStack {
			ScrollViewReader { proxy in
				ZStack(alignment: .trailing) {
					List {
						ForEach(sections, id: \.letter) { section in
							Section {
								ForEach(section.contacts) { contact in
									NavigationLink {
										ContactDetailView(contact: contact)
									} label: {
										NativeContactRow(contact: contact)
									}
								}
							} header: {
								Text(section.letter).id(section.letter)
							}
						}
					}
					.listStyle(.plain)

					if searchText.isEmpty {
						SectionIndexRail(letters: sections.map(\.letter)) { letter in
							proxy.scrollTo(letter, anchor: .top)
						}
					}
				}
			}
			.navigationTitle("Contacts")
			.navigationBarTitleDisplayMode(.inline)
			.searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button { showNewContact = true } label: { Image(systemName: "plus") }
				}
			}
			.sheet(isPresented: $showNewContact, onDismiss: { model.load() }) {
				NewContactSheet()
			}
			.overlay {
				if model.accessDenied {
					ContentUnavailableView(
						"No Access to Contacts",
						systemImage: "person.crop.circle.badge.exclamationmark",
						description: Text("Allow contact access in Settings > Privacy.")
					)
				}
			}
		}
		.onAppear { model.load() }
	}

	private var filtered: [DeviceContact] {
		guard !searchText.isEmpty else { return model.contacts }
		return model.contacts.filter {
			$0.displayName.localizedCaseInsensitiveContains(searchText)
				|| $0.numbers.contains { $0.value.localizedCaseInsensitiveContains(searchText) }
		}
	}

	private var sections: [(letter: String, contacts: [DeviceContact])] {
		let grouped = Swift.Dictionary(grouping: filtered, by: \.sectionLetter)
		return grouped.keys.sorted { a, b in
			if a == "#" { return false }
			if b == "#" { return true }
			return a < b
		}.map { (letter: $0, contacts: grouped[$0] ?? []) }
	}
}

struct NativeContactRow: View {
	let contact: DeviceContact

	var body: some View {
		HStack(spacing: 12) {
			if let data = contact.thumbnail, let image = UIImage(data: data) {
				Image(uiImage: image)
					.resizable().scaledToFill()
					.frame(width: 40, height: 40)
					.clipShape(Circle())
			} else {
				InitialsAvatar(name: contact.displayName, size: 40)
			}
			(Text(contact.givenName.isEmpty ? "" : contact.givenName + " ")
				+ Text(contact.familyName).fontWeight(.semibold))
				.lineLimit(1)
			if contact.displayName == contact.organization && !contact.organization.isEmpty {
				Text(contact.organization).fontWeight(.semibold).lineLimit(1)
			}
		}
		.padding(.vertical, 2)
	}
}

struct SectionIndexRail: View {
	let letters: [String]
	let onTap: (String) -> Void

	var body: some View {
		VStack(spacing: 1) {
			ForEach(letters, id: \.self) { letter in
				Text(letter)
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(Color.accentColor)
					.frame(width: 16)
					.onTapGesture { onTap(letter) }
			}
		}
		.padding(.trailing, 2)
	}
}

struct ContactDetailView: View {
	let contact: DeviceContact

	var body: some View {
		List {
			Section {
				VStack(spacing: 10) {
					if let data = contact.thumbnail, let image = UIImage(data: data) {
						Image(uiImage: image)
							.resizable().scaledToFill()
							.frame(width: 90, height: 90)
							.clipShape(Circle())
					} else {
						InitialsAvatar(name: contact.displayName, size: 90)
					}
					Text(contact.displayName).font(.title2.weight(.semibold))
				}
				.frame(maxWidth: .infinity)
				.listRowBackground(Color.clear)
			}
			Section {
				ForEach(contact.numbers, id: \.value) { number in
					Button {
						AstradialDialer.call(number.value)
					} label: {
						VStack(alignment: .leading, spacing: 2) {
							Text(number.label).font(.footnote).foregroundStyle(.secondary)
							Text(number.value).foregroundStyle(Color.accentColor)
						}
					}
				}
			}
		}
		.navigationBarTitleDisplayMode(.inline)
	}
}

struct NewContactSheet: UIViewControllerRepresentable {
	@Environment(\.dismiss) private var dismiss

	func makeUIViewController(context: Context) -> UINavigationController {
		let controller = CNContactViewController(forNewContact: nil)
		controller.delegate = context.coordinator
		return UINavigationController(rootViewController: controller)
	}

	func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

	func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

	final class Coordinator: NSObject, CNContactViewControllerDelegate {
		let dismiss: () -> Void
		init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
		func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
			dismiss()
		}
	}
}

// MARK: - Favourites

struct Favourite: Codable, Identifiable, Equatable {
	var id = UUID()
	var name: String
	var label: String
	var number: String
}

final class FavouritesStore: ObservableObject {
	@Published var favourites: [Favourite] {
		didSet { save() }
	}

	private static let key = "astradial_favourites"

	init() {
		if let data = UserDefaults.standard.data(forKey: Self.key),
		   let decoded = try? JSONDecoder().decode([Favourite].self, from: data) {
			favourites = decoded
		} else {
			favourites = []
		}
	}

	private func save() {
		if let data = try? JSONEncoder().encode(favourites) {
			UserDefaults.standard.set(data, forKey: Self.key)
		}
	}
}

struct FavouritesTabView: View {
	@StateObject private var store = FavouritesStore()
	@State private var showPicker = false

	var body: some View {
		NavigationStack {
			List {
				ForEach(store.favourites) { favourite in
					HStack(spacing: 12) {
						InitialsAvatar(name: favourite.name, size: 44)
						VStack(alignment: .leading, spacing: 2) {
							Text(favourite.name).font(.body.weight(.semibold))
							HStack(spacing: 4) {
								Image(systemName: "phone.fill").font(.caption2)
								Text(favourite.label).font(.subheadline)
							}
							.foregroundStyle(.secondary)
						}
						Spacer()
					}
					.contentShape(Rectangle())
					.onTapGesture { AstradialDialer.call(favourite.number) }
				}
				.onDelete { store.favourites.remove(atOffsets: $0) }
				.onMove { store.favourites.move(fromOffsets: $0, toOffset: $1) }
			}
			.listStyle(.plain)
			.navigationTitle("Favourites")
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { EditButton() }
				ToolbarItem(placement: .topBarTrailing) {
					Button { showPicker = true } label: { Image(systemName: "plus") }
				}
			}
			.overlay {
				if store.favourites.isEmpty {
					ContentUnavailableView(
						"No Favourites",
						systemImage: "star",
						description: Text("Tap + to add a contact you call often.")
					)
				}
			}
			.sheet(isPresented: $showPicker) {
				FavouriteContactPicker { name, label, number in
					store.favourites.append(Favourite(name: name, label: label, number: number))
				}
			}
		}
	}
}

struct FavouriteContactPicker: UIViewControllerRepresentable {
	let onPick: (String, String, String) -> Void

	func makeUIViewController(context: Context) -> CNContactPickerViewController {
		let picker = CNContactPickerViewController()
		picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
		picker.predicateForSelectionOfContact = NSPredicate(value: false)
		picker.delegate = context.coordinator
		return picker
	}

	func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

	func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

	final class Coordinator: NSObject, CNContactPickerDelegate {
		let onPick: (String, String, String) -> Void
		init(onPick: @escaping (String, String, String) -> Void) { self.onPick = onPick }

		func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
			guard let phone = contactProperty.value as? CNPhoneNumber else { return }
			let name = CNContactFormatter.string(from: contactProperty.contact, style: .fullName) ?? phone.stringValue
			let label = CNLabeledValue<NSString>.localizedString(forLabel: contactProperty.label ?? CNLabelPhoneNumberMobile)
			onPick(name, label, phone.stringValue)
		}
	}
}

// MARK: - Voicemail

struct VoicemailTabView: View {
	@State private var noVoicemailConfigured = false

	var body: some View {
		NavigationStack {
			ContentUnavailableView(
				"No Voicemail",
				systemImage: "recordingtape",
				description: Text("Voicemail messages you receive will appear here.")
			)
			.navigationTitle("Voicemail")
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Call Voicemail") { callVoicemail() }
				}
			}
			.alert("No voicemail number configured for this account.", isPresented: $noVoicemailConfigured) {
				Button("OK", role: .cancel) {}
			}
		}
	}

	private func callVoicemail() {
		CoreContext.shared.doOnCoreQueue { core in
			if let voicemail = core.defaultAccount?.params?.voicemailAddress {
				TelecomManager.shared.doCallOrJoinConf(address: voicemail)
			} else {
				DispatchQueue.main.async { noVoicemailConfigured = true }
			}
		}
	}
}
