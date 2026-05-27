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
        stateRow(title: "Glasses view", value: displayViewModel.isStreamingCameraToDisplay ? "Camera stream" : "Controls")
        stateRow(title: "Frame", value: displayViewModel.hasCameraFrame ? "Ready" : "--")
        stateRow(title: "Hand", value: displayViewModel.heroCards.isEmpty ? "--" : displayViewModel.heroCards.joined(separator: " "))
        stateRow(title: "Board", value: displayViewModel.boardCards.isEmpty ? "--" : displayViewModel.boardCards.joined(separator: " "))
        stateRow(title: "Table scan", value: displayViewModel.isScanningTable ? "Scanning" : "Ready")
        stateRow(title: "Recording", value: displayViewModel.isRecordingTable ? "\(displayViewModel.recordingSampleCount) frames" : "Off")
        stateRow(title: "Solver API", value: displayViewModel.solverAPIStatus)
        stateRow(title: "Decision", value: displayViewModel.canGetDecision ? "Ready" : "Locked")
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
        Text("Glasses controls")
          .font(.headline)

        Text("Scan hand reads just your two cards. Start recording fuses the video feed over time, then End recording builds the table state.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer()

      VStack(spacing: 12) {
        Button {
          Task { await displayViewModel.sendPokerVisionReady() }
        } label: {
          Label("Open on display", systemImage: "eyeglasses")
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(red: 0.08, green: 0.46, blue: 0.28), in: Capsule())
        }
        .buttonStyle(.plain)

        Button {
          Task { await displayViewModel.initializeDemoPlay() }
        } label: {
          Label("Initialize play", systemImage: "play.rectangle.on.rectangle")
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(displayViewModel.isDemoMode ? Color.orange : Color(red: 0.08, green: 0.46, blue: 0.28), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(displayViewModel.isScanningTable)

        Button {
          Task {
            if displayViewModel.isStreamingCameraToDisplay {
              await displayViewModel.stopCameraStreamOnDisplay()
            } else {
              await displayViewModel.startCameraStreamOnDisplay()
            }
          }
        } label: {
          Label(
            displayViewModel.isStreamingCameraToDisplay ? "Stop glasses camera stream" : "Stream camera on glasses",
            systemImage: displayViewModel.isStreamingCameraToDisplay ? "stop.circle.fill" : "rectangle.inset.filled.and.person.filled"
          )
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(displayViewModel.isStreamingCameraToDisplay ? Color.red : Color(red: 0.08, green: 0.46, blue: 0.28), in: Capsule())
        }
        .buttonStyle(.plain)

        HStack(spacing: 12) {
          Button {
            Task { await displayViewModel.analyzeHeroHand() }
          } label: {
            Label("Scan hand", systemImage: "person.crop.rectangle")
              .font(.body.weight(.semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 16)
              .background(Color(red: 0.08, green: 0.46, blue: 0.28), in: Capsule())
          }
          .buttonStyle(.plain)
          .disabled(displayViewModel.isScanningTable || displayViewModel.isRecordingTable)

          Button {
            Task { await displayViewModel.analyzeTable() }
          } label: {
            Label(displayViewModel.isScanningTable ? "Scanning table" : "Analyze table", systemImage: "sparkle.magnifyingglass")
              .font(.body.weight(.semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 16)
              .background(Color(red: 0.08, green: 0.46, blue: 0.28), in: Capsule())
          }
          .buttonStyle(.plain)
          .disabled(displayViewModel.isScanningTable || displayViewModel.isRecordingTable)
        }

        Button {
          Task {
            if displayViewModel.isRecordingTable {
              await displayViewModel.stopTableRecording()
            } else {
              await displayViewModel.startTableRecording()
            }
          }
        } label: {
          Label(
            displayViewModel.isRecordingTable ? "End recording" : "Start recording",
            systemImage: displayViewModel.isRecordingTable ? "stop.circle.fill" : "record.circle"
          )
          .font(.body.weight(.semibold))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 16)
          .background(displayViewModel.isRecordingTable ? Color.red : Color(red: 0.08, green: 0.46, blue: 0.28), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(displayViewModel.isScanningTable)

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
          .foregroundStyle(displayViewModel.canGetDecision ? .white : .secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(displayViewModel.canGetDecision ? Color(red: 0.08, green: 0.46, blue: 0.28) : Color(.tertiarySystemBackground), in: Capsule())
      }

      VStack(alignment: .leading, spacing: 8) {
        Text(displayViewModel.displayMirrorTitle)
          .font(.title3.weight(.bold))
          .lineLimit(2)
          .minimumScaleFactor(0.8)

        Text(displayViewModel.displayMirrorPrimary)
          .font(.body.weight(.medium))
          .foregroundStyle(.primary)
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

          ForEach(displayViewModel.latestTableCandidates) { candidate in
            let detection = candidate.detection
            let rect = detectionRect(
              detection.boundingBox,
              imageSize: frame.size,
              containerSize: proxy.size
            )
            let color = candidateColor(candidate)
            if let quad = detection.orientedQuad {
              Path { path in
                let points = quad.points.map {
                  displayPoint($0, imageSize: frame.size, containerSize: proxy.size)
                }
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() {
                  path.addLine(to: point)
                }
                path.closeSubpath()
              }
              .stroke(color.opacity(candidate.isUsableForState ? 1.0 : 0.55), lineWidth: candidate.isUsableForState ? 3 : 2)
            } else {
              RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(candidate.isUsableForState ? 1.0 : 0.55), lineWidth: candidate.isUsableForState ? 3 : 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            }

            Text("\(zoneLabel(candidate.zone)) \(detection.apiLabel) \(Int(detection.confidence * 100))%")
              .font(.caption2.weight(.bold))
              .foregroundStyle(candidate.zone == .unknown ? .white : .black)
              .lineLimit(1)
              .padding(.horizontal, 7)
              .padding(.vertical, 4)
              .background(color.opacity(candidate.isUsableForState ? 1.0 : 0.72), in: Capsule())
              .position(x: rect.midX, y: max(12, rect.minY - 12))
          }
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
              Text("Waiting for glasses camera")
                .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.secondary)
          }
      }

      Text("Glasses camera")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.62), in: Capsule())
        .padding(12)

      Text(displayViewModel.detectionStatus)
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

  private func candidateColor(_ candidate: TableCardCandidate) -> Color {
    switch candidate.zone {
    case .hero:
      return Color.cyan
    case .board:
      return Color.green
    case .unknown:
      return Color.orange
    }
  }

  private func zoneLabel(_ zone: TableCardZone) -> String {
    switch zone {
    case .hero:
      return "Hero"
    case .board:
      return "Board"
    case .unknown:
      return "Seen"
    }
  }

  private func detectionRect(
    _ normalizedBox: CGRect,
    imageSize: CGSize,
    containerSize: CGSize
  ) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else {
      return .zero
    }

    let scale = max(
      containerSize.width / imageSize.width,
      containerSize.height / imageSize.height
    )
    let scaledWidth = imageSize.width * scale
    let scaledHeight = imageSize.height * scale
    let offsetX = (containerSize.width - scaledWidth) / 2
    let offsetY = (containerSize.height - scaledHeight) / 2

    let x = offsetX + normalizedBox.minX * scaledWidth
    let y = offsetY + (1 - normalizedBox.maxY) * scaledHeight
    let width = normalizedBox.width * scaledWidth
    let height = normalizedBox.height * scaledHeight

    return CGRect(x: x, y: y, width: width, height: height)
  }

  private func displayPoint(
    _ normalizedPoint: CGPoint,
    imageSize: CGSize,
    containerSize: CGSize
  ) -> CGPoint {
    guard imageSize.width > 0, imageSize.height > 0 else {
      return .zero
    }

    let scale = max(
      containerSize.width / imageSize.width,
      containerSize.height / imageSize.height
    )
    let scaledWidth = imageSize.width * scale
    let scaledHeight = imageSize.height * scale
    let offsetX = (containerSize.width - scaledWidth) / 2
    let offsetY = (containerSize.height - scaledHeight) / 2

    return CGPoint(
      x: offsetX + normalizedPoint.x * scaledWidth,
      y: offsetY + (1 - normalizedPoint.y) * scaledHeight
    )
  }
}
