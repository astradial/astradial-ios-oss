/*
 * Astradial Tickets tab (replaces Voicemail).
 *
 * Mirrors the editor's tickets page (docs: features/tickets-architecture.md):
 * GET /api/v1/tickets (status_counts, actionable-first ordering),
 * GET /api/v1/tickets/:id/events (call timeline),
 * PATCH /api/v1/tickets/:id (status/priority), POST /api/v1/tickets.
 * Native iOS list UI; call-back dials through liblinphone.
 */

import SwiftUI
import UserNotifications

// MARK: - Models

struct Ticket: Decodable, Identifiable {
	let id: String
	let callerNumber: String?
	let callerName: String?
	let source: String?
	let priority: String?
	let status: String?
	let missedCount: Int?
	let lastCallAt: String?
	let closedAt: String?
	let callbackFoundAt: String?
	let callbackDurationSec: Int?
	let summary: String?

	enum CodingKeys: String, CodingKey {
		case id, source, priority, status, summary
		case callerNumber = "caller_number"
		case callerName = "caller_name"
		case missedCount = "missed_count"
		case lastCallAt = "last_call_at"
		case closedAt = "closed_at"
		case callbackFoundAt = "callback_found_at"
		case callbackDurationSec = "callback_duration_sec"
	}

	var displayName: String {
		if let name = callerName, !name.isEmpty { return name }
		return callerNumber ?? "Unknown"
	}

	var summaryLine: String {
		if let summary, !summary.isEmpty { return summary }
		let count = missedCount ?? 1
		return "\(count) missed call\(count == 1 ? "" : "s")"
	}

	var lastCallDate: Date? { Ticket.parse(lastCallAt) }
	var callbackDate: Date? { Ticket.parse(callbackFoundAt) }
	var closedDate: Date? { Ticket.parse(closedAt) }

	static func parse(_ string: String?) -> Date? {
		guard let string else { return nil }
		let iso = ISO8601DateFormatter()
		iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return iso.date(from: string)
			?? { let f = ISO8601DateFormatter(); return f.date(from: string) }()
			?? CDRCall.fallbackFormatter.date(from: string)
	}
}

struct TicketStatusCounts: Decodable {
	let open: Int?
	let inProgress: Int?
	let closed: Int?

	enum CodingKeys: String, CodingKey {
		case open, closed
		case inProgress = "in_progress"
	}
}

struct TicketsResponse: Decodable {
	let data: [Ticket]?
	let tickets: [Ticket]?  // tolerate either payload key
	let statusCounts: TicketStatusCounts?

	enum CodingKeys: String, CodingKey {
		case data, tickets
		case statusCounts = "status_counts"
	}

	var list: [Ticket] { data ?? tickets ?? [] }
}

struct TicketEvent: Decodable, Identifiable {
	struct Meta: Decodable {
		let duration: Int?
		let billsec: Int?
		let disposition: String?
	}
	let id: String?
	let linkedid: String?
	let kind: String?
	let occurredAt: String?
	let meta: Meta?

	enum CodingKeys: String, CodingKey {
		case id, linkedid, kind, meta
		case occurredAt = "occurred_at"
	}

	var identity: String { id ?? linkedid ?? UUID().uuidString }
	var date: Date? { Ticket.parse(occurredAt) }

	var badge: (label: String, color: Color) {
		switch kind {
		case "bot_dropped": return ("Bot Dropped", .orange)
		case "outbound_attempt": return ("Outbound", .blue)
		default: return ("Missed", .red)
		}
	}
}

struct TicketEventsResponse: Decodable {
	let data: [TicketEvent]?
	let events: [TicketEvent]?
	var list: [TicketEvent] { data ?? events ?? [] }
}

// MARK: - API

extension AstradialAPI {
	private func ticketsRequest(path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
		guard AstradialAPIConfig.isConfigured else { throw AstradialAPIError.notConfigured }
		var request = URLRequest(url: URL(string: "\(AstradialAPIConfig.base)\(path)")!)
		request.httpMethod = method
		request.setValue(AstradialAPIConfig.apiKey, forHTTPHeaderField: "X-API-Key")
		if let body {
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.httpBody = try JSONSerialization.data(withJSONObject: body)
		}
		return request
	}

	private func run(_ request: URLRequest) async throws -> Data {
		let (data, response) = try await URLSession.shared.data(for: request)
		if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
			throw AstradialAPIError.http(http.statusCode)
		}
		return data
	}

	func fetchTickets() async throws -> TicketsResponse {
		let data = try await run(ticketsRequest(path: "/api/v1/tickets?limit=100"))
		return try JSONDecoder().decode(TicketsResponse.self, from: data)
	}

	func fetchTicketEvents(id: String) async throws -> [TicketEvent] {
		let data = try await run(ticketsRequest(path: "/api/v1/tickets/\(id)/events"))
		return try JSONDecoder().decode(TicketEventsResponse.self, from: data).list
	}

	func patchTicket(id: String, fields: [String: Any]) async throws {
		_ = try await run(ticketsRequest(path: "/api/v1/tickets/\(id)", method: "PATCH", body: fields))
	}

	func createTicket(callerNumber: String, callerName: String, summary: String) async throws {
		_ = try await run(ticketsRequest(path: "/api/v1/tickets", method: "POST", body: [
			"caller_number": callerNumber,
			"caller_name": callerName,
			"source": "manual",
			"summary": summary
		]))
	}
}

// MARK: - View model

@MainActor
final class TicketsViewModel: ObservableObject {
	// Shared so the tab bar badge updates without visiting the tab.
	static let shared = TicketsViewModel()

	enum Filter: String, CaseIterable {
		case open = "Open"
		case inProgress = "In Progress"
		case closed = "Closed"
		case all = "All"
	}

	@Published var tickets: [Ticket] = []
	@Published var counts: TicketStatusCounts?
	@Published var filter: Filter = .open
	@Published var isSampleData = true
	@Published var errorMessage: String?
	@Published var updateError: String?

	var openCount: Int {
		counts?.open ?? tickets.filter { $0.status == "open" }.count
	}

	var filtered: [Ticket] {
		switch filter {
		case .open: return tickets.filter { $0.status == "open" }
		case .inProgress: return tickets.filter { $0.status == "in_progress" }
		case .closed: return tickets.filter { $0.status == "closed" || $0.status == "archived" }
		case .all: return tickets
		}
	}

	func reload() async {
		// Demo data only when no API key is configured; on real errors keep
		// last-known-good tickets and surface the failure.
		guard AstradialAPIConfig.isConfigured else {
			tickets = Self.sampleTickets
			counts = TicketStatusCounts(open: 3, inProgress: 1, closed: 2)
			isSampleData = true
			errorMessage = nil
			updateSystemBadge()
			return
		}
		do {
			let response = try await AstradialAPI.shared.fetchTickets()
			tickets = response.list
			counts = response.statusCounts
			isSampleData = false
			errorMessage = nil
		} catch {
			isSampleData = false
			errorMessage = error.localizedDescription
		}
		updateSystemBadge()
	}

	// Mirrors the open-ticket count onto the home-screen app icon,
	// like the Phone app's missed-call badge.
	private func updateSystemBadge() {
		let open = openCount
		let center = UNUserNotificationCenter.current()
		center.requestAuthorization(options: [.badge]) { _, _ in
			center.setBadgeCount(open)
		}
	}

	func set(_ ticket: Ticket, fields: [String: Any]) async {
		guard !isSampleData else { return }
		do {
			try await AstradialAPI.shared.patchTicket(id: ticket.id, fields: fields)
		} catch {
			updateError = "Couldn't update ticket: \(error.localizedDescription)"
		}
		await reload()
	}

	nonisolated static let sampleTickets: [Ticket] = [
		Ticket(id: "1", callerNumber: "9944421125", callerName: "Saravanan", source: "missed_call",
			   priority: "urgent", status: "open", missedCount: 4,
			   lastCallAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-1800)),
			   closedAt: nil, callbackFoundAt: nil, callbackDurationSec: nil, summary: nil),
		Ticket(id: "2", callerNumber: "9842726558", callerName: nil, source: "queue_timeout",
			   priority: "high", status: "open", missedCount: 2,
			   lastCallAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-7200)),
			   closedAt: nil,
			   callbackFoundAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-3600)),
			   callbackDurationSec: 49, summary: nil),
		Ticket(id: "3", callerNumber: "9677949475", callerName: "Thangavelu Hospital", source: "missed_call",
			   priority: "normal", status: "open", missedCount: 1,
			   lastCallAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-9000)),
			   closedAt: nil, callbackFoundAt: nil, callbackDurationSec: nil, summary: nil),
		Ticket(id: "4", callerNumber: "9876501234", callerName: "Kailash", source: "missed_call",
			   priority: "normal", status: "in_progress", missedCount: 1,
			   lastCallAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-86000)),
			   closedAt: nil, callbackFoundAt: nil, callbackDurationSec: nil, summary: nil),
		Ticket(id: "5", callerNumber: "9123456780", callerName: nil, source: "manual",
			   priority: "normal", status: "closed", missedCount: 1,
			   lastCallAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-172800)),
			   closedAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-86400)),
			   callbackFoundAt: nil, callbackDurationSec: nil, summary: "Asked for pricing brochure"),
		Ticket(id: "6", callerNumber: "9000011111", callerName: "Front Desk", source: "missed_call",
			   priority: "high", status: "closed", missedCount: 3,
			   lastCallAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-259200)),
			   closedAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-172800)),
			   callbackFoundAt: nil, callbackDurationSec: nil, summary: nil)
	]
}

// MARK: - Views

struct TicketsTabView: View {
	@ObservedObject private var viewModel = TicketsViewModel.shared
	@State private var showNewTicket = false

	var body: some View {
		NavigationStack {
			List {
				if viewModel.isSampleData {
					Section {
						HStack(spacing: 8) {
							Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
							Text("Sample data — connect the Astradial API in Analytics → Settings.")
								.font(.footnote)
						}
					}
				}

				Section {
					countsStrip
						.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
				}

				Section {
					ForEach(viewModel.filtered) { ticket in
						NavigationLink {
							TicketDetailView(ticket: ticket, viewModel: viewModel)
						} label: {
							TicketRow(ticket: ticket)
						}
						.swipeActions(edge: .trailing) {
							if ticket.status != "closed" {
								Button("Close") {
									Task { await viewModel.set(ticket, fields: ["status": "closed"]) }
								}
								.tint(.green)
								Button("In Progress") {
									Task { await viewModel.set(ticket, fields: ["status": "in_progress"]) }
								}
								.tint(.orange)
							}
						}
					}
				}
			}
			.listStyle(.insetGrouped)
			.navigationTitle("Tickets")
			.toolbar {
				ToolbarItem(placement: .principal) {
					Picker("Filter", selection: $viewModel.filter) {
						ForEach(TicketsViewModel.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
					}
					.pickerStyle(.segmented)
					.frame(maxWidth: 320)
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button { showNewTicket = true } label: { Image(systemName: "plus") }
				}
			}
			.refreshable { await viewModel.reload() }
			.overlay {
				if viewModel.filtered.isEmpty {
					ContentUnavailableView("No Tickets", systemImage: "checkmark.circle",
						description: Text("Missed calls automatically become tickets."))
				}
			}
			.sheet(isPresented: $showNewTicket) {
				NewTicketSheet(viewModel: viewModel)
			}
			.alert(
				viewModel.updateError ?? "",
				isPresented: Binding(
					get: { viewModel.updateError != nil },
					set: { if !$0 { viewModel.updateError = nil } }
				)
			) {
				Button("OK", role: .cancel) {}
			}
		}
		.task { await viewModel.reload() }
	}

	private var countsStrip: some View {
		HStack(spacing: 12) {
			CountPill(label: "Open", count: viewModel.counts?.open ?? 0, color: .red)
			CountPill(label: "In Progress", count: viewModel.counts?.inProgress ?? 0, color: .orange)
			CountPill(label: "Closed", count: viewModel.counts?.closed ?? 0, color: .green)
			Spacer()
		}
	}
}

struct CountPill: View {
	let label: String
	let count: Int
	let color: Color

	var body: some View {
		HStack(spacing: 5) {
			Circle().fill(color).frame(width: 8, height: 8)
			Text("\(label): \(count)").font(.footnote.weight(.medium))
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 5)
		.background(color.opacity(0.12), in: Capsule())
	}
}

struct TicketRow: View {
	let ticket: Ticket

	var body: some View {
		HStack(spacing: 12) {
			InitialsAvatar(name: ticket.displayName, size: 42)
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 6) {
					Text(ticket.displayName)
						.font(.body.weight(.semibold))
						.lineLimit(1)
					PriorityBadge(priority: ticket.priority)
				}
				Text(ticket.summaryLine)
					.font(.subheadline)
					.foregroundStyle(.secondary)
				if let callback = ticket.callbackDate {
					HStack(spacing: 4) {
						Image(systemName: "phone.arrow.down.left")
						Text("Answered call \(ticket.callbackDurationSec ?? 0)s at \(callback.formatted(date: .omitted, time: .shortened))")
					}
					.font(.caption)
					.foregroundStyle(.green)
				}
				if let closed = ticket.closedDate {
					Text("Closed \(closed.formatted(.relative(presentation: .named)))")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			Spacer()
			if let last = ticket.lastCallDate {
				Text(relativeDate(time_t(last.timeIntervalSince1970)))
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
		}
		.padding(.vertical, 2)
	}
}

struct PriorityBadge: View {
	let priority: String?

	var body: some View {
		switch priority {
		case "urgent":
			Text("URGENT").font(.caption2.weight(.bold)).foregroundStyle(.white)
				.padding(.horizontal, 6).padding(.vertical, 2)
				.background(Color.red, in: Capsule())
		case "high":
			Text("HIGH").font(.caption2.weight(.bold)).foregroundStyle(.white)
				.padding(.horizontal, 6).padding(.vertical, 2)
				.background(Color.orange, in: Capsule())
		default:
			EmptyView()
		}
	}
}

struct TicketDetailView: View {
	let ticket: Ticket
	@ObservedObject var viewModel: TicketsViewModel
	@Environment(\.dismiss) private var dismiss
	@State private var events: [TicketEvent] = []
	@State private var eventsLoaded = false

	var body: some View {
		List {
			Section {
				HStack(spacing: 14) {
					InitialsAvatar(name: ticket.displayName, size: 56)
					VStack(alignment: .leading, spacing: 2) {
						Text(ticket.displayName).font(.title3.weight(.semibold))
						if ticket.callerName != nil, let number = ticket.callerNumber {
							Text(number).font(.footnote).foregroundStyle(.secondary)
						}
						HStack(spacing: 6) {
							StatusBadge(status: ticket.status)
							PriorityBadge(priority: ticket.priority)
						}
					}
				}
				Button {
					if let number = ticket.callerNumber { AstradialDialer.call(number) }
				} label: {
					Label("Call Back", systemImage: "phone.fill")
				}
			}

			if let callback = ticket.callbackDate {
				Section {
					Label {
						Text("Reached: answered call of \(ticket.callbackDurationSec ?? 0)s at \(callback.formatted(date: .abbreviated, time: .shortened))")
					} icon: {
						Image(systemName: "phone.arrow.down.left").foregroundStyle(.green)
					}
					.font(.subheadline)
				} footer: {
					Text("This number had a completed call after the last miss — likely already reached.")
				}
			}

			Section("Manage") {
				Picker("Status", selection: statusBinding) {
					Text("Open").tag("open")
					Text("In Progress").tag("in_progress")
					Text("Closed").tag("closed")
				}
				Picker("Priority", selection: priorityBinding) {
					Text("Normal").tag("normal")
					Text("High").tag("high")
					Text("Urgent").tag("urgent")
				}
			}

			Section("Details") {
				LabeledContent("Source", value: sourceLabel)
				LabeledContent("Missed attempts", value: "\(eventsLoaded && !events.isEmpty ? events.count : (ticket.missedCount ?? 1))")
				if let last = ticket.lastCallDate {
					LabeledContent("Last call", value: last.formatted(date: .abbreviated, time: .shortened))
				}
				if let closed = ticket.closedDate {
					LabeledContent("Closed", value: closed.formatted(date: .abbreviated, time: .shortened))
				}
			}

			Section("Call Timeline") {
				if events.isEmpty {
					Text(eventsLoaded ? "No recorded attempts (legacy ticket)." : "Loading…")
						.font(.footnote).foregroundStyle(.secondary)
				}
				ForEach(events) { event in
					HStack {
						Text(event.badge.label)
							.font(.caption2.weight(.bold))
							.foregroundStyle(.white)
							.padding(.horizontal, 6).padding(.vertical, 2)
							.background(event.badge.color, in: Capsule())
						if let date = event.date {
							Text(date.formatted(date: .abbreviated, time: .shortened))
								.font(.subheadline)
						}
						Spacer()
						if let duration = event.meta?.duration {
							Text("\(duration)s").font(.footnote).foregroundStyle(.secondary)
						}
					}
				}
			}
		}
		.navigationTitle("Ticket")
		.navigationBarTitleDisplayMode(.inline)
		.task {
			if !viewModel.isSampleData {
				events = (try? await AstradialAPI.shared.fetchTicketEvents(id: ticket.id)) ?? []
			} else if ticket.id == "1" {
				events = [
					TicketEvent(id: "e1", linkedid: "l1", kind: "missed",
						occurredAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-1800)),
						meta: .init(duration: 22, billsec: 0, disposition: "NO ANSWER")),
					TicketEvent(id: "e2", linkedid: "l2", kind: "missed",
						occurredAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-5400)),
						meta: .init(duration: 18, billsec: 0, disposition: "NO ANSWER"))
				]
			}
			eventsLoaded = true
		}
	}

	private var sourceLabel: String {
		switch ticket.source {
		case "queue_timeout": return "Queue timeout"
		case "bot_dropped": return "Bot dropped"
		case "manual": return "Manual"
		default: return "Missed call"
		}
	}

	private var statusBinding: Binding<String> {
		Binding(
			get: { ticket.status ?? "open" },
			set: { newValue in Task { await viewModel.set(ticket, fields: ["status": newValue]); dismiss() } }
		)
	}

	private var priorityBinding: Binding<String> {
		Binding(
			get: { ticket.priority ?? "normal" },
			set: { newValue in Task { await viewModel.set(ticket, fields: ["priority": newValue]); dismiss() } }
		)
	}
}

struct StatusBadge: View {
	let status: String?

	var body: some View {
		Text(label)
			.font(.caption2.weight(.bold))
			.foregroundStyle(color)
			.padding(.horizontal, 6).padding(.vertical, 2)
			.background(color.opacity(0.15), in: Capsule())
	}

	private var label: String {
		switch status {
		case "in_progress": return "IN PROGRESS"
		case "closed": return "CLOSED"
		case "archived": return "ARCHIVED"
		default: return "OPEN"
		}
	}

	private var color: Color {
		switch status {
		case "in_progress": return .orange
		case "closed", "archived": return .green
		default: return .red
		}
	}
}

struct NewTicketSheet: View {
	@ObservedObject var viewModel: TicketsViewModel
	@Environment(\.dismiss) private var dismiss
	@State private var number = ""
	@State private var name = ""
	@State private var summary = ""
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Form {
				Section("Caller") {
					TextField("Phone number", text: $number)
						.keyboardType(.phonePad)
					TextField("Name (optional)", text: $name)
				}
				Section("Summary") {
					TextField("What does this ticket cover?", text: $summary, axis: .vertical)
						.lineLimit(3...5)
				}
				if let error {
					Text(error).font(.footnote).foregroundStyle(.red)
				}
			}
			.navigationTitle("New Ticket")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("Cancel") { dismiss() }
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button("Create") {
						Task {
							do {
								try await AstradialAPI.shared.createTicket(
									callerNumber: number, callerName: name, summary: summary)
								await viewModel.reload()
								dismiss()
							} catch {
								self.error = error.localizedDescription
							}
						}
					}
					.disabled(number.isEmpty)
				}
			}
		}
	}
}
