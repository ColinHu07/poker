/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// DisplayAccessApp.swift
//
// Main entry point for the DisplayAccess app demonstrating the Meta Wearables DAT SDK
// Display module. This app shows how to send visual content to wearable display devices.
//

import MWDATCore
import SwiftUI

private enum AppTab: Hashable {
  case samples
  case settings
}

@main
struct DisplayAccessApp: App {
  @State private var wearablesViewModel: WearablesViewModel
  @State private var displayViewModel: DisplayViewModel
  @State private var selectedTab: AppTab = .samples
  @Environment(\.scenePhase) private var scenePhase

  init() {
    do {
      try Wearables.configure()
    } catch {
      #if DEBUG
      NSLog("[DisplayAccess] Failed to configure Wearables SDK: \(error)")
      #endif
    }

    let wearables = Wearables.shared
    self._wearablesViewModel = State(wrappedValue: WearablesViewModel(wearables: wearables))
    self._displayViewModel = State(wrappedValue: DisplayViewModel(wearables: wearables))
  }

  var body: some Scene {
    WindowGroup {
      TabView(selection: $selectedTab) {
        NavigationStack {
          SampleAppsView(displayViewModel: displayViewModel)
        }
        .tabItem {
          Label("Samples", systemImage: "eyeglasses")
        }
        .tag(AppTab.samples)

        NavigationStack {
          SettingsView(
            viewModel: SettingsViewModel(
              registrationState: wearablesViewModel.registrationState,
              deviceItemStates: wearablesViewModel.deviceItemStates,
              requiresFirmwareUpdate: wearablesViewModel.requiresFirmwareUpdate,
              requiresDATAppUpdate: displayViewModel.requiresDATAppUpdate,
              connectGlasses: {
                Task {
                  await wearablesViewModel.connectGlasses()
                }
              },
              disconnectGlasses: {
                Task {
                  await wearablesViewModel.disconnectGlasses()
                }
              },
              openFirmwareUpdate: {
                wearablesViewModel.openFirmwareUpdate()
              },
              openDATGlassesAppUpdate: {
                wearablesViewModel.openDATGlassesAppUpdate()
              }
            )
          )
        }
        .tabItem {
          Label("Settings", systemImage: "gearshape")
        }
        .tag(AppTab.settings)
      }
      .onChange(of: displayViewModel.didFailToStartSession) { _, didFailToStartSession in
        if didFailToStartSession {
          selectedTab = .settings
          displayViewModel.clearSessionStartFailure()
        }
      }
      .alert("Error", isPresented: $wearablesViewModel.showError) {
        Button("OK") { wearablesViewModel.dismissError() }
      } message: {
        Text(wearablesViewModel.errorMessage)
      }
      .onAppear {
        UIApplication.shared.isIdleTimerDisabled = true
      }
      .onChange(of: scenePhase) { _, phase in
        UIApplication.shared.isIdleTimerDisabled = phase == .active
      }

      RegistrationView(viewModel: wearablesViewModel)
    }
  }
}
