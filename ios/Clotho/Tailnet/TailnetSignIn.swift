#if CLOTHO_TAILNET
import AuthenticationServices
import UIKit

/// The node's browser sign-in, in an ASWebAuthenticationSession sheet. Tailscale's login never redirects to an
/// app scheme, so the sheet has no callback: TailnetController closes it (`finished`) once the node runs.
///
/// Ephemeral (no shared Safari cookies): no "wants to use … to sign in" alert, which UI tests need, at the cost
/// of signing in to Tailscale again on each device.
@MainActor
final class TailnetSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Outcome { case finished, cancelledByUser, failed }

    /// The open sheet and the caller waiting on it. Whoever closes it first (the sheet's handler, `finished`, or a
    /// new `present`) takes it and resumes the caller, once: after a programmatic cancel the handler may never run.
    private struct Open {
        var id: Int
        var session: ASWebAuthenticationSession
        var continuation: CheckedContinuation<Outcome, Never>
    }
    private var open: Open?
    private var lastID = 0

    /// Shows `url` and returns when the sheet closes: `finished` when the node ran (or Stop), `cancelledByUser`
    /// when the user closed it first.
    func present(_ url: URL) async -> Outcome {
        finished()
        lastID += 1
        let id = lastID
        return await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
                MainActor.assumeIsolated {
                    let outcome: Outcome
                    if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        outcome = .cancelledByUser
                    } else {
                        outcome = error == nil ? .finished : .failed
                    }
                    self?.resolve(id, outcome)
                }
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            self.open = Open(id: id, session: session, continuation: continuation)
            if !session.start() { self.resolve(id, .failed) }
        }
    }

    /// Resumes the caller of presentation `id`, if it's still the open one.
    private func resolve(_ id: Int, _ outcome: Outcome) {
        guard let open, open.id == id else { return }
        self.open = nil
        open.continuation.resume(returning: outcome)
    }

    /// The node runs: close the sheet, and the caller gets `finished` now.
    func finished() {
        guard let open else { return }
        self.open = nil
        open.session.cancel()
        open.continuation.resume(returning: .finished)
    }

    func cancel() { finished() }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
#endif
