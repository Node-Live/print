import Foundation

/// Fetches the document a `{"url": …}` print request names: http or https only, redirects followed, 30 s for the
/// whole download, at most `LocalAPI.maxBodyBytes`.
enum Download {
    struct Failure: Error {
        let message: String
    }

    static func fetch(_ url: URL) throws(Failure) -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 30
        let receiver = Receiver()
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        session.dataTask(with: url).resume()
        receiver.done.wait()
        if let failure = receiver.failure { throw Failure(message: "\(url.absoluteString): \(failure)") }
        return receiver.data
    }

    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        var failure: String?

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                failure = "HTTP \(http.statusCode)."
            } else if response.expectedContentLength > LocalAPI.maxBodyBytes {
                failure = "the document is larger than 52,428,800 bytes."
            }
            completionHandler(failure == nil ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            self.data.append(data)
            if self.data.count > LocalAPI.maxBodyBytes {
                failure = "the document is larger than 52,428,800 bytes."
                dataTask.cancel()
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            let scheme = request.url?.scheme?.lowercased()
            completionHandler(scheme == "http" || scheme == "https" ? request : nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if failure == nil, let error {
                failure = (error as? URLError)?.code == .timedOut
                    ? "no complete answer within 30 s."
                    : "\(error.localizedDescription)."
            }
            done.signal()
        }
    }
}
