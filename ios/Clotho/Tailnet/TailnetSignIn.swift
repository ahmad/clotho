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

    private var session: ASWebAuthenticationSession?
    private var closedByUs = false

    /// Shows `url` and returns when the sheet closes: `finished` when the node ran (or Stop), `cancelledByUser`
    /// when the user closed it first.
    func present(_ url: URL) async -> Outcome {
        cancel()
        closedByUs = false
        return await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
                MainActor.assumeIsolated {
                    let byUs = self?.closedByUs ?? true
                    self?.session = nil
                    if byUs {
                        continuation.resume(returning: .finished)
                    } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        continuation.resume(returning: .cancelledByUser)
                    } else {
                        continuation.resume(returning: error == nil ? .finished : .failed)
                    }
                }
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(returning: .failed)
            }
        }
    }

    /// The node runs: close the sheet.
    func finished() {
        guard let session else { return }
        closedByUs = true
        session.cancel()
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
