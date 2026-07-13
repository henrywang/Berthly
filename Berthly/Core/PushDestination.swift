import Foundation

/// The registry host of an image reference, or `nil` if the reference carries no explicit host
/// (a Docker Hub short name like `user/web:1.4`, or a purely local name like `web:1.4`).
///
/// Follows Docker/OCI's rule: the segment before the first `/` is a registry host only if it looks
/// like one — it contains a `.` or `:` (a domain or host:port), or is exactly `localhost`.
/// Otherwise that segment is a repository namespace and the reference has no host.
///
/// The native `ClientImage.push` (and the `container` CLI's own `image push` command) requires a
/// host in the reference and never infers one — unlike `docker push`, a domain-less destination is
/// a guaranteed failure here, not a Docker Hub default. The push sheet uses this to block Push
/// outright when `nil` (offering a one-tap `docker.io/` prefix instead), and to check whether the
/// user has credentials for the target registry when a host is present.
func registryHost(forReference reference: String) -> String? {
    let trimmed = reference.trimmingCharacters(in: .whitespaces)
    guard let slash = trimmed.firstIndex(of: "/") else { return nil }
    let firstSegment = String(trimmed[trimmed.startIndex..<slash])
    guard firstSegment == "localhost" || firstSegment.contains(".") || firstSegment.contains(":") else {
        return nil
    }
    return firstSegment
}
