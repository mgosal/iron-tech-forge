# Security Anti-Patterns

> **The Security Gate agent must check every diff against these patterns.**

## OWASP Top 10 — Code-Level Patterns

### A01: Broken Access Control
- Direct object references without authorization checks
- Missing role/permission validation before data access
- Path traversal via user input in file operations (`../`, `..\\`)
- CORS misconfiguration (`Access-Control-Allow-Origin: *` with credentials)

### A02: Cryptographic Failures
- Hardcoded secrets, API keys, passwords, or tokens
- Use of weak algorithms: MD5, SHA1 for security purposes
- Missing encryption for sensitive data at rest or in transit
- Deterministic IVs or nonces

### A03: Injection
- SQL queries built with string concatenation or template literals
- Shell command execution with unsanitized user input (`exec`, `system`, `child_process`)
- LDAP injection via unescaped filter values
- XSS via innerHTML, dangerouslySetInnerHTML, or unescaped template output

### A04: Insecure Design
- Missing rate limiting on authentication endpoints
- Missing input validation/sanitization
- Business logic that can be bypassed by skipping steps

### A05: Security Misconfiguration
- Debug mode enabled in production config
- Default credentials left in place
- Stack traces or internal errors exposed to users
- Permissive file permissions (0777, world-readable secrets)

### A06: Vulnerable Components
- Dependencies with known CVEs
- Unpinned dependency versions (`*`, `latest`)
- Dependencies from untrusted sources

### A07: Authentication Failures
- Credentials in URL parameters or logs
- Missing account lockout after failed attempts
- Session tokens that don't expire or rotate
- Passwords stored in plaintext or with reversible encoding

### A08: Data Integrity Failures
- Deserialization of untrusted data (pickle, yaml.load, JSON.parse of user input into eval)
- Missing integrity checks on downloaded packages or updates

### A09: Logging Failures
- Sensitive data in logs (passwords, tokens, PII)
- Missing audit logging for security-critical actions
- Log injection via unsanitized user input

### A10: SSRF
- HTTP requests to user-controlled URLs without allowlist validation
- DNS rebinding opportunities
- Internal service URLs exposed via error messages

## Secret Patterns (Regex)

```
# AWS
AKIA[0-9A-Z]{16}
aws_secret_access_key\s*=\s*[A-Za-z0-9/+=]{40}

# GitHub
gh[ps]_[A-Za-z0-9_]{36,}
github_pat_[A-Za-z0-9_]{22,}

# Generic API Keys
[Aa][Pp][Ii][-_]?[Kk][Ee][Yy]\s*[:=]\s*['"][A-Za-z0-9]{16,}['"]

# Private Keys
-----BEGIN (RSA |EC |DSA )?PRIVATE KEY-----

# JWT
eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+

# High-entropy strings (32+ hex chars)
[0-9a-f]{32,}
```

## File Patterns to Flag

- `.env` files committed to the repo
- `*.pem`, `*.key`, `*.p12` files
- Files named `secrets`, `credentials`, `password` (any extension)
- Config files with embedded passwords or tokens
