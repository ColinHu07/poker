/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// PokerVisionApp.swift
//
// Main entry point for the PokerVision sample app demonstrating the Meta Wearables DAT SDK.
// This app shows how to connect to wearable devices (like Ray-Ban Meta smart glasses),
// stream live video from their cameras, and capture photos. It provides a complete example
// of DAT SDK integration including device registration, permissions, and media streaming.
//

import Foundation
import MWDATCore
import SwiftUI

#if DEBUG
import MWDATMockDevice
#endif

@main
struct PokerVisionApp: App {
  private let wearables: WearablesInterface
  @StateObject private var wearablesViewModel: WearablesViewModel

  init() {
    do {
      try Wearables.configure()
    } catch {
      #if DEBUG
      NSLog("[PokerVision] Failed to configure Wearables SDK: \(error)")
      #endif
    }

    #if DEBUG
    // Auto-configure MockDeviceKit when launched by XCUITests
    if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
      let device = MockDeviceKit.shared.pairRaybanMeta()
      let cameraKit = device.services.camera
      guard let videoURL = Bundle.main.url(forResource: "plant", withExtension: "mp4"),
        let imageURL = Bundle.main.url(forResource: "plant", withExtension: "png")
      else {
        fatalError("Test resources not found - are you running a Release build?")
      }
      cameraKit.setCameraFeed(fileURL: videoURL)
      cameraKit.setCapturedImage(fileURL: imageURL)

      device.powerOn()
      device.don()
    }
    #endif

    let wearables = Wearables.shared
    self.wearables = wearables
    self._wearablesViewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
  }

  var body: some Scene {
    WindowGroup {
      ZStack {
        MainAppView(wearables: Wearables.shared, viewModel: wearablesViewModel)
          .alert("Error", isPresented: $wearablesViewModel.showError) {
            Button("OK") {
              wearablesViewModel.dismissError()
            }
          } message: {
            Text(wearablesViewModel.errorMessage)
          }

        RegistrationView(viewModel: wearablesViewModel)
      }
    }
  }
}
