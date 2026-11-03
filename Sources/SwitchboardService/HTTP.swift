import Foundation
import SwitchboardCore

/// Sends the request and waits for the answer: the status, the headers with
/// lowercased names, and the body.
func httpRequest(_ request: URLRequest) throws -> (Int, [String: String], Data) {
  let done = DispatchSemaphore(value: 0)
  var result: Result<(Int, [String: String], Data), Error> = .failure(APIError("no answer"))
  URLSession.shared.dataTask(with: request) { data, response, error in
    if let error {
      result = .failure(error)
    } else if let http = response as? HTTPURLResponse {
      var headers: [String: String] = [:]
      for (k, v) in http.allHeaderFields { headers["\(k)".lowercased()] = "\(v)" }
      result = .success((http.statusCode, headers, data ?? Data()))
    }
    done.signal()
  }.resume()
  done.wait()
  return try result.get()
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
