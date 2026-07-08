// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import SwiftUI

/// First-run welcome shown once (gated on `preferences.hasSeenOnboarding`). Two cards: what the
/// app does, then the Accessibility ask framed by benefit. Skippable at every step — the buttons
/// and the window's close box both finish via `store.completeOnboarding()`.
struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore
    // Test hook (like MONITORFLUX_SELECT): a screenshot run can jump straight to a card.
    @State private var page = Int(ProcessInfo.processInfo.environment["MONITORFLUX_ONBOARDING_PAGE"] ?? "") ?? 0

    private static let pageCount = 2

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if page == 0 {
                    intro.transition(.opacity)
                } else {
                    accessibility.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 36)
            .padding(.top, 40)

            footer
        }
        .frame(width: 460, height: 460)
    }

    // MARK: - Cards

    private var intro: some View {
        VStack(spacing: 18) {
            heroIcon("sun.horizon.fill", tint: [.orange, .indigo])

            VStack(spacing: 6) {
                Text("Welcome to MonitorFlux")
                    .font(.title.weight(.semibold))
                Text("Two things, done well.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                featureRow(
                    "thermometer.sun.fill", tint: .orange,
                    title: "Warm your screen on a schedule",
                    detail: "Ease the color from cool daylight to a warm night — gentler on your eyes after dark."
                )
                featureRow(
                    "slider.horizontal.3", tint: .blue,
                    title: "Control every monitor from the menu bar",
                    detail: "Brightness, contrast, and volume for each display, right where you need them."
                )
            }
            .padding(.top, 4)
        }
    }

    private var accessibility: some View {
        VStack(spacing: 18) {
            heroIcon("keyboard", tint: [.blue, .teal])

            VStack(spacing: 6) {
                Text("Use your brightness keys")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("So the keys on your keyboard can drive your monitors")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("MonitorFlux needs Accessibility permission to route brightness-key shortcuts to the display under your pointer or directly to the built-in screen. Volume keys stay with macOS unless you record them later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<Self.pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.primary.opacity(0.7) : Color.primary.opacity(0.18))
                        .frame(width: 7, height: 7)
                }
            }

            Spacer()

            if page == 0 {
                secondaryButton("Skip") { store.completeOnboarding() }
                primaryButton("Continue") { withAnimation(.snappy(duration: 0.2)) { page = 1 } }
            } else {
                secondaryButton("Back") { withAnimation(.snappy(duration: 0.2)) { page = 0 } }
                secondaryButton("Not now") { store.completeOnboarding() }
                primaryButton("Enable…") {
                    store.setKeyboardControl(true)
                    store.completeOnboarding()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.bar)
    }

    // MARK: - Building blocks

    /// A large rounded glyph with a soft cool→warm gradient halo behind it — the app's
    /// blue↔amber motif as the first thing a new user sees.
    private func heroIcon(_ symbol: String, tint: [Color]) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 46, weight: .medium))
            .foregroundStyle(
                LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: 96, height: 96)
            .background(
                Circle().fill(
                    LinearGradient(
                        colors: tint.map { $0.opacity(0.14) },
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            )
    }

    /// A filled accent CTA drawn with an explicit capsule + white label via `.plain`, so it
    /// renders identically whether or not the window is key. The system `.borderedProminent`
    /// default button drops its label on recent macOS when the window isn't active — which a menu-bar
    /// app's welcome window often isn't (a status-item panel holds key).
    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.accentColor))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func featureRow(_ symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(tint)
                .frame(width: 26, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
