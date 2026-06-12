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
	@ObservedObject private var session = MDSession.shared
	@StateObject private var callViewModel = CallViewModel()

	@State private var selectedTab: Int = {
		if let env = ProcessInfo.processInfo.environment["DEFAULT_TAB"], let tab = Int(env) { return tab }
		// Owners who signed in during onboarding land on Analytics.
		return UserDefaults.standard.object(forKey: "astradial_initial_tab") as? Int ?? 3
	}()

	var body: some View {
		ZStack {
			TabView(selection: $selectedTab) {
				// Analytics + Tickets are company tools — signed-in users only.
				if session.isSignedIn {
					AnalyticsTabView()
						.tabItem { Label("Analytics", systemImage: "waveform.path.ecg") }
						.tag(0)
				}
				RecentsTabView()
					.tabItem { Label("Recents", systemImage: "clock.fill") }
					.tag(1)
				ContactsTabView()
					.tabItem { Label("Contacts", systemImage: "person.crop.circle.fill") }
					.tag(2)
				KeypadTabView()
					.tabItem { Label("Keypad", systemImage: "circle.grid.3x3.fill") }
					.tag(3)
				if session.isSignedIn {
					TicketsTabView()
						.tabItem { Label("Tickets", systemImage: "phone.arrow.down.left.fill") }
						.badge(ticketsViewModel.openCount)
						.tag(4)
				}
			}
			.task { await TicketsViewModel.shared.reload() }
			.onChange(of: session.isSignedIn) { _, signedIn in
				selectedTab = signedIn ? 0 : 3
				Task { await TicketsViewModel.shared.reload() }
			}

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
	@State private var showSettings = false

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
		Button {
			showSettings = true
		} label: {
			chipLabel
		}
		.buttonStyle(.plain)
		.sheet(isPresented: $showSettings) {
			AstradialSettingsView()
		}
	}

	@ViewBuilder
	private var chipLabel: some View {
		// Profile avatar when signed in, settings gear otherwise — both
		// open Settings (account, SIP line, sign-in).
		if MDSession.shared.isSignedIn {
			InitialsAvatar(name: MDSession.shared.displayName, size: 34)
		} else {
			Image(systemName: "gearshape.circle.fill")
				.font(.system(size: 34))
				.symbolRenderingMode(.hierarchical)
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

// MARK: - Contacts (org directory: Users & Extensions, no device contacts)

struct OrgUser: Decodable, Identifiable {
	let id: String
	let extensionNumber: String?
	let fullName: String?
	let role: String?
	let status: String?
	let routingType: String?
	let ringTarget: String?
	let phoneNumber: String?

	enum CodingKeys: String, CodingKey {
		case id, role, status
		case extensionNumber = "extension"
		case fullName = "full_name"
		case routingType = "routing_type"
		case ringTarget = "ring_target"
		case phoneNumber = "phone_number"
	}

	var displayName: String {
		if let name = fullName, !name.isEmpty { return name }
		return extensionNumber.map { "Ext \($0)" } ?? "User"
	}

	var sectionLetter: String {
		let letter = String(displayName.prefix(1)).uppercased()
		return letter.first?.isLetter == true ? letter : "#"
	}

	var isActive: Bool { (status ?? "active") == "active" }
}

extension AstradialAPI {
	func fetchUsers() async throws -> [OrgUser] {
		guard AstradialAPIConfig.isConfigured else { throw AstradialAPIError.notConfigured }
		var request = URLRequest(url: URL(string: "\(AstradialAPIConfig.base)/api/v1/users")!)
		request.setValue("Bearer \(try await PlatformAuth.shared.bearerToken())", forHTTPHeaderField: "Authorization")
		let (data, response) = try await AstradialHTTP.session.data(for: request)
		if let http = response as? HTTPURLResponse, http.statusCode != 200 {
			throw AstradialAPIError.http(http.statusCode)
		}
		guard let users = try? JSONDecoder().decode([OrgUser].self, from: data) else {
			throw AstradialAPIError.decodeError(endpoint: "users", body: data)
		}
		return users
	}

	func setUserStatus(id: String, active: Bool) async throws {
		var request = URLRequest(url: URL(string: "\(AstradialAPIConfig.base)/api/v1/users/\(id)")!)
		request.httpMethod = "PUT"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("Bearer \(try await PlatformAuth.shared.bearerToken())", forHTTPHeaderField: "Authorization")
		request.httpBody = try JSONSerialization.data(withJSONObject: ["status": active ? "active" : "inactive"])
		let (_, response) = try await AstradialHTTP.session.data(for: request)
		if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
			throw AstradialAPIError.http(http.statusCode)
		}
	}
}

@MainActor
final class OrgDirectoryModel: ObservableObject {
	@Published var users: [OrgUser] = []
	@Published var errorMessage: String?
	@Published var loaded = false

	func load() async {
		guard AstradialAPIConfig.isConfigured else {
			users = []
			loaded = true
			return
		}
		do {
			users = try await AstradialAPI.shared.fetchUsers()
				.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
			errorMessage = nil
		} catch {
			errorMessage = error.localizedDescription
		}
		loaded = true
	}

	func setActive(_ user: OrgUser, _ active: Bool) {
		// Optimistic flip; reload on failure.
		if let index = users.firstIndex(where: { $0.id == user.id }) {
			var copy = users
			copy[index] = OrgUser(
				id: user.id, extensionNumber: user.extensionNumber, fullName: user.fullName,
				role: user.role, status: active ? "active" : "inactive",
				routingType: user.routingType, ringTarget: user.ringTarget, phoneNumber: user.phoneNumber
			)
			users = copy
		}
		Task {
			do {
				try await AstradialAPI.shared.setUserStatus(id: user.id, active: active)
			} catch {
				errorMessage = "Couldn't update \(user.displayName): \(error.localizedDescription)"
				await load()
			}
		}
	}
}

struct ContactsTabView: View {
	@StateObject private var model = OrgDirectoryModel()
	@ObservedObject private var session = MDSession.shared
	@State private var searchText = ""

	var body: some View {
		NavigationStack {
			ScrollViewReader { proxy in
				ZStack(alignment: .trailing) {
					List {
						ForEach(sections, id: \.letter) { section in
							Section {
								ForEach(section.users) { user in
									OrgUserRow(user: user, model: model)
								}
							} header: {
								Text(section.letter).id(section.letter)
							}
						}
					}
					.listStyle(.plain)

					if searchText.isEmpty && sections.count > 1 {
						SectionIndexRail(letters: sections.map(\.letter)) { letter in
							proxy.scrollTo(letter, anchor: .top)
						}
					}
				}
			}
			.navigationTitle("Contacts")
			.navigationBarTitleDisplayMode(.inline)
			.searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
			.refreshable { await model.load() }
			.overlay {
				if !session.isSignedIn {
					ContentUnavailableView(
						"Sign In Required",
						systemImage: "person.2.fill",
						description: Text("Your team's extensions appear here after you sign in (Keypad → account chip).")
					)
				} else if model.loaded && model.users.isEmpty {
					ContentUnavailableView("No Team Members", systemImage: "person.2")
				}
			}
			.alert(
				model.errorMessage ?? "",
				isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
			) {
				Button("OK", role: .cancel) {}
			}
		}
		.task { await model.load() }
		.onChange(of: session.isSignedIn) { _, _ in
			Task { await model.load() }
		}
	}

	private var filtered: [OrgUser] {
		guard !searchText.isEmpty else { return model.users }
		return model.users.filter {
			$0.displayName.localizedCaseInsensitiveContains(searchText)
				|| ($0.extensionNumber ?? "").localizedCaseInsensitiveContains(searchText)
		}
	}

	private var sections: [(letter: String, users: [OrgUser])] {
		let grouped = Swift.Dictionary(grouping: filtered, by: \.sectionLetter)
		return grouped.keys.sorted { a, b in
			if a == "#" { return false }
			if b == "#" { return true }
			return a < b
		}.map { (letter: $0, users: grouped[$0] ?? []) }
	}
}

struct OrgUserRow: View {
	let user: OrgUser
	@ObservedObject var model: OrgDirectoryModel

	var body: some View {
		NavigationLink {
			OrgUserDetailView(user: user, model: model)
		} label: {
			HStack(spacing: 12) {
				InitialsAvatar(name: user.displayName, size: 40)
				VStack(alignment: .leading, spacing: 1) {
					nameText
						.lineLimit(1)
					if let ext = user.extensionNumber {
						Text("ext \(ext)")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				Spacer()
				VStack(spacing: 1) {
					Toggle("", isOn: Binding(
						get: { user.isActive },
						set: { model.setActive(user, $0) }
					))
					.labelsHidden()
					.tint(.green)
					Text(user.isActive ? "Work" : "Out")
						.font(.caption2)
						.foregroundStyle(user.isActive ? .green : .secondary)
				}
			}
			.padding(.vertical, 2)
		}
	}

	private var nameText: Text {
		let parts = user.displayName.split(separator: " ")
		if parts.count > 1, let last = parts.last {
			let first = parts.dropLast().joined(separator: " ")
			return Text(first + " ") + Text(String(last)).fontWeight(.semibold)
		}
		return Text(user.displayName).fontWeight(.semibold)
	}
}

struct OrgUserDetailView: View {
	let user: OrgUser
	@ObservedObject var model: OrgDirectoryModel

	private var current: OrgUser { model.users.first(where: { $0.id == user.id }) ?? user }

	var body: some View {
		List {
			Section {
				VStack(spacing: 10) {
					InitialsAvatar(name: current.displayName, size: 90)
					Text(current.displayName).font(.title2.weight(.semibold))
					if let ext = current.extensionNumber {
						Text("ext \(ext)").foregroundStyle(.secondary)
					}
				}
				.frame(maxWidth: .infinity)
				.listRowBackground(Color.clear)
			}
			Section {
				if let ext = current.extensionNumber {
					Button {
						AstradialDialer.call(ext)
					} label: {
						Label("Call ext \(ext)", systemImage: "phone.fill")
					}
				}
				Toggle(isOn: Binding(
					get: { current.isActive },
					set: { model.setActive(current, $0) }
				)) {
					Label(current.isActive ? "At Work" : "Out", systemImage: current.isActive ? "person.fill.checkmark" : "person.fill.xmark")
				}
				.tint(.green)
			}
			Section("Details") {
				if let role = current.role {
					LabeledContent("Role", value: role.capitalized)
				}
				if let routing = current.routingType ?? current.ringTarget {
					LabeledContent("Routing", value: routing.capitalized)
				}
				if let phone = current.phoneNumber, !phone.isEmpty {
					Button {
						AstradialDialer.call(phone)
					} label: {
						LabeledContent("Mobile") { Text(phone).foregroundStyle(Color.accentColor) }
					}
					.buttonStyle(.plain)
				}
			}
		}
		.navigationBarTitleDisplayMode(.inline)
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
