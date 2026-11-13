import Foundation
import SwitchboardCore
import os

/// Sends the request and waits for the answer: the status, the headers with
/// lowercased names, and the body.
func httpRequest(_ request: URLRequest) throws -> (Int, [String: String], Data) {
  let done = DispatchSemaphore(value: 0)
  let result = OSAllocatedUnfairLock<Result<(Int, [String: String], Data), Error>>(
    initialState: .failure(APIError("no answer")))
  URLSession.shared.dataTask(with: request) { data, response, error in
    if let error {
      result.withLock { $0 = .failure(error) }
    } else if let http = response as? HTTPURLResponse {
      var headers: [String: String] = [:]
      for (k, v) in http.allHeaderFields { headers["\(k)".lowercased()] = "\(v)" }
      let answer = (http.statusCode, headers, data ?? Data())
      result.withLock { $0 = .success(answer) }
    }
    done.signal()
  }.resume()
  done.wait()
  return try result.withLock { $0 }.get()
}

/// Sends one POST of `body` as JSON and waits for the answer.
func postJSON(_ url: URL, headers: [String: String], body: JSON) throws -> (Int, [String: String], Data) {
  var req = URLRequest(url: url, timeoutInterval: 30)
  req.httpMethod = "POST"
  req.setValue("application/json", forHTTPHeaderField: "Content-Type")
  for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
  req.httpBody = Data(body.text.utf8)
  return try httpRequest(req)
}
