// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import SwiftUI

/// The Follow-sunset "Location" row. Resolved state: the place name — or the raw coordinates
/// when no name is known — plus a Change button. Editing state: one search field over the
/// offline place index with up to five inline suggestion rows; the field understands a city
/// prefix ("seatt"), a 5-digit US ZIP, or raw coordinates ("47.61, -122.33"), which is what
/// replaced the two bare latitude/longitude fields. Return accepts the top match, Esc cancels.
///
/// Search state (query, suggestions) is view-local; the store is touched exactly once, when a
/// result is picked (`applyPlace`) — never per keystroke.
struct LocationField: View {
    @EnvironmentObject private var store: AppStore
    @State private var isEditing: Bool
    @State private var query: String
    @State private var suggestions: [Place] = []
    /// Loaded lazily on first edit; nil until then (suggestion rows just don't appear yet).
    @State private var index: PlaceIndex?
    @FocusState private var fieldFocused: Bool

    init() {
        // Verification hook: `MONITORFLUX_LOCATION_QUERY=seat` opens the row in its editing
        // state pre-filled, so a screenshot run can capture the suggestion list without
        // scripting focus and keystrokes.
        let seeded = ProcessInfo.processInfo.environment["MONITORFLUX_LOCATION_QUERY"]
        _isEditing = State(initialValue: seeded != nil)
        _query = State(initialValue: seeded ?? "")
    }

    var body: some View {
        if isEditing {
            editor
        } else {
            LabeledContent("Location") {
                HStack(spacing: 10) {
                    Text(store.preferences.locationDisplayLabel)
                        .foregroundStyle(.secondary)
                    Button("Change…") {
                        beginEditing()
                    }
                    .settingsPushButton()
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Location", text: $query, prompt: Text("City or ZIP"))
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(acceptTopSuggestion)
                Button("Cancel") {
                    endEditing()
                }
                .settingsPushButton()
            }

            ForEach(Array(suggestions.enumerated()), id: \.offset) { _, place in
                Button {
                    pick(place)
                } label: {
                    HStack {
                        // Tinted on the Text itself: .plain buttons flatten a foreground
                        // style set on the button, and gray rows don't read as clickable.
                        Text(suggestionLabel(for: place))
                            .zoomFont(.callout)
                            .foregroundStyle(Color.accentColor)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if suggestions.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty, index != nil {
                Text("No matches. Try a larger nearby city, a US ZIP, or coordinates like 47.61, -122.33.")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onExitCommand {
            endEditing()
        }
        .task {
            index = await store.loadedPlaceIndex()
            refreshSuggestions()
        }
        .onChange(of: query) {
            refreshSuggestions()
        }
    }

    /// Coordinates get an action verb — they're a command ("use this spot"), not a found place.
    private func suggestionLabel(for place: Place) -> String {
        place.countryCode.isEmpty && place.zip == nil
            ? "Use \(place.name)"
            : place.qualifiedName
    }

    private func beginEditing() {
        query = ""
        suggestions = []
        isEditing = true
        // The field mounts on this render pass; focus lands next turn of the run loop.
        DispatchQueue.main.async {
            fieldFocused = true
        }
    }

    private func endEditing() {
        isEditing = false
        query = ""
        suggestions = []
    }

    private func refreshSuggestions() {
        suggestions = index?.search(query) ?? []
    }

    private func acceptTopSuggestion() {
        guard let first = suggestions.first else {
            return
        }
        pick(first)
    }

    private func pick(_ place: Place) {
        store.applyPlace(place)
        endEditing()
    }
}
