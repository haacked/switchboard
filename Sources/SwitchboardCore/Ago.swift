/// How long ago `ms` was, in the largest whole unit: "12s", "5m", "3h", or "2d". A time in the future prints "0s".
public func ago(_ ms: Int64, now: Int64 = nowMs()) -> String {
  let s = max(0, (now - ms) / 1000)
  if s < 60 { return "\(s)s" }
  if s < 3600 { return "\(s / 60)m" }
  if s < 86400 { return "\(s / 3600)h" }
  return "\(s / 86400)d"
}
