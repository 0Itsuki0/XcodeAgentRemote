//
//  NetworkErrorView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/27.
//

import SwiftUI

struct NetworkErrorView: View {
    let error: NetworkError
    let retry: () -> Void
    let retryDisabled: Bool
    var body: some View {
        ContentUnavailableView {
            Label(
                "Error fetching data",
                systemImage: "laptopcomputer.trianglebadge.exclamationmark"
            )
        } description: {
            let recovery: String =
                error.recoverySuggestion.map {
                    "\n\n\($0.trimmed)"
                } ?? ""
            Text(error.localizedDescription.trimmed + recovery)
                .padding(.top, UIConstants.standardSpacing)
        } actions: {
            Button("Retry", action: retry)
                .disabled(retryDisabled)
        }
    }
}
