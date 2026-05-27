/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import SwiftUI

struct SampleAppsView: View {
  var displayViewModel: DisplayViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Image(systemName: "suit.club.fill")
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 58, height: 58)
            .background(Color(red: 0.08, green: 0.46, blue: 0.28), in: RoundedRectangle(cornerRadius: 16))

          Spacer()

          connectionPill
        }

        Text("PokerVision")
          .font(.largeTitle.weight(.bold))
          .foregroundStyle(.primary)

        Text("Display overlay for table capture and action advice.")
          .font(.body)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 16) {
        stateRow(title: "Display", value: displayViewModel.isConnected ? "Connected" : "Ready")
        stateRow(title: "Camera", value: displayViewModel.isCameraStreaming ? "Streaming" : "Waiting")
        stateRow(title: "Captured image", value: displayViewModel.currentCameraFrame == nil ? "--" : "Ready")
        stateRow(title: "Photo size", value: displayViewModel.capturedPhotoSize)
        stateRow(title: "Analysis API", value: displayViewModel.geminiAPIStatus)
        stateRow(title: "Image analysis", value: displayViewModel.visionStatus)
        stateRow(title: "Hand", value: displayViewModel.heroCards.isEmpty ? "--" : displayViewModel.heroCards.joined(separator: " "))
        stateRow(title: "Board", value: displayViewModel.boardCards.isEmpty ? "--" : displayViewModel.boardCards.joined(separator: " "))
        stateRow(title: "Prediction", value: displayViewModel.predictionStatus)
        if let warning = displayViewModel.tableWarning {
          stateRow(title: "Warning", value: warning)
        }
      }
      .padding(22)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))

      cameraPreview

      displayMirror

      VStack(alignment: .leading, spacing: 12) {
        Text("Photo prediction")
          .font(.headline)

        Text("Initialize the glasses camera, take one still image, then run prediction from the captured table state.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer()

      VStack(spacing: 12) {
        Button {
          Task { await displayViewModel.initializePokerVision() }
        } label: {
          Label(displayViewModel.isInitializingPokerVision ? "Initializing" : "Initialize glasses", systemImage: "eyeglasses")
            .font(.body.weight(.semibold))
            .foregroundStyle(displayViewModel.isInitializingPokerVision ? .secondary : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(.tertiarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(displayViewModel.isInitializingPokerVision || displayViewModel.isCapturingImage || displayViewModel.isRunningVision || displayViewModel.isRunningPrediction)

        HStack(spacing: 12) {
          Button {
            Task { await displayViewModel.takeImage() }
          } label: {
            Label(displayViewModel.isCapturingImage ? "Taking" : "Take image", systemImage: "camera.fill")
              .font(.body.weight(.semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 16)
              .background(Color(red: 0.08, green: 0.46, blue: 0.28), in: Capsule())
          }
          .buttonStyle(.plain)
          .disabled(displayViewModel.isInitializingPokerVision || displayViewModel.isCapturingImage || displayViewModel.isRunningVision || displayViewModel.isRunningPrediction)

          Button {
            Task { await displayViewModel.runPrediction() }
          } label: {
            Label(displayViewModel.isRunningPrediction ? "Running" : "Run prediction", systemImage: "checkmark.seal")
              .font(.body.weight(.semibold))
              .foregroundStyle(displayViewModel.canRunPrediction ? .white : .secondary)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 16)
              .background(displayViewModel.canRunPrediction ? Color(red: 0.08, green: 0.46, blue: 0.28) : Color(.tertiarySystemBackground), in: Capsule())
          }
          .buttonStyle(.plain)
          .disabled(!displayViewModel.canRunPrediction)
        }
      }
    }
    }
    .padding(.horizontal, 24)
    .padding(.top, 44)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .toolbar(.hidden, for: .navigationBar)
  }

  private var connectionPill: some View {
    Text(displayViewModel.isConnected ? "Display connected" : "Display ready")
      .font(.caption.weight(.semibold))
      .foregroundStyle(displayViewModel.isConnected ? .green : .secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(Color(.tertiarySystemBackground), in: Capsule())
  }

  private var displayMirror: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center) {
        Label("Display mirror", systemImage: "eyeglasses")
          .font(.headline)
        Spacer()
        Text(displayViewModel.displayMirrorAction)
          .font(.caption.weight(.semibold))
          .foregroundStyle(displayViewModel.canRunPrediction ? .white : .secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(displayViewModel.canRunPrediction ? Color(red: 0.08, green: 0.46, blue: 0.28) : Color(.tertiarySystemBackground), in: Capsule())
      }

      VStack(alignment: .leading, spacing: 8) {
        Text(displayViewModel.displayMirrorTitle)
          .font(.title3.weight(.bold))
          .lineLimit(2)
          .minimumScaleFactor(0.8)

        Text(displayViewModel.displayMirrorPrimary)
          .font(displayViewModel.displayMirrorTitle == "Best action" ? .title2.weight(.bold) : .body.weight(.medium))
          .foregroundStyle(.primary)
          .lineLimit(2)
          .minimumScaleFactor(0.75)
          .fixedSize(horizontal: false, vertical: true)

        Text(displayViewModel.displayMirrorSecondary)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 10) {
        mirrorChip(title: "Hand", value: displayViewModel.heroCards.isEmpty ? "--" : displayViewModel.heroCards.joined(separator: " "))
        mirrorChip(title: "Board", value: displayViewModel.boardCards.isEmpty ? "--" : displayViewModel.boardCards.joined(separator: " "))
      }

      if !displayViewModel.geminiRawResponse.isEmpty {
        Text(displayViewModel.geminiRawResponse)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(6)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
      }
    }
    .padding(22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
  }

  private func mirrorChip(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
  }

  @ViewBuilder
  private var cameraPreview: some View {
    ZStack(alignment: .bottomLeading) {
      if let frame = displayViewModel.currentCameraFrame {
        GeometryReader { proxy in
          Image(uiImage: frame)
            .resizable()
            .scaledToFill()
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .clipped()
      } else {
        Rectangle()
          .fill(Color(.secondarySystemBackground))
          .frame(maxWidth: .infinity)
          .frame(height: 260)
          .overlay {
            VStack(spacing: 10) {
              Image(systemName: "video.slash")
                .font(.system(size: 28, weight: .semibold))
              Text("Take an image")
                .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.secondary)
          }
      }

      Text("Captured image")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.62), in: Capsule())
        .padding(12)

      Text(displayViewModel.visionStatus)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.62), in: Capsule())
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
    .clipShape(RoundedRectangle(cornerRadius: 24))
  }

  private func stateRow(title: String, value: String) -> some View {
    HStack {
      Text(title)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
    }
  }
}
