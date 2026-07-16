// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// One stat tile in the menu-bar dashboard grid.
struct SummaryTile: View {
    let title: String
    let value: Int
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value, format: .number.notation(.compactName))
                .font(.system(.body, design: .rounded, weight: .semibold))
                .contentTransition(.numericText())
                .help("\(value.formatted()) tokens (estimated)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

#Preview {
    HStack {
        SummaryTile(title: "Input", value: 1_234, systemImage: "arrow.down.circle")
        SummaryTile(title: "Output", value: 56_789, systemImage: "arrow.up.circle")
    }
    .padding()
}
