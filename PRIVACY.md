# DiskOUT Privacy Policy

Effective: August 27, 2026

DiskOUT is supplied by an independent developer under the **LIMOD** brand. Privacy questions may be sent to [sukmack@gmail.com](mailto:sukmack@gmail.com) or submitted through [DiskOUT Support](https://github.com/yooongZa/DiskOUT/issues).

## 1. Data that stays on your Mac

Disk discovery, disk names, volume names, file paths, eject and mount operations, excluded-volume settings, and hotkey settings are processed locally. DiskOUT does not send disk names, volume names, file paths, or file contents to its billing service.

The app stores preferences in macOS user defaults. For lifecycle counts, it stores a separate random installation UUID, random event UUIDs, the last-seen app version/build, any pending Sparkle update target, and an acknowledgement queue in its Application Support directory. When billing is configured, it stores a random billing installation UUID, a random 256-bit binding secret, the latest signed entitlement, and restore-attempt metadata in the macOS Keychain. A recovery code contains the binding secret and must be treated as private.

## 2. Premium billing data

When DiskOUT checks, purchases, transfers, or displays details for Premium, its Cloudflare-hosted billing service may process:

- the random DiskOUT installation UUID;
- the binding secret transiently in encrypted HTTPS request memory for authentication, and its one-way SHA-256 hash for stored comparison;
- a short-lived signed claim token transiently for verification, plus a one-way hash of its nonce, its attempt count, and expiry;
- Paddle customer, transaction, price, item, adjustment, and event identifiers;
- purchase, refund, dispute, entitlement, and event timestamps or status; and
- network metadata necessarily handled by Cloudflare, such as IP address and request headers.

The billing database does not store the raw binding secret, recovery code, raw claim token, raw webhook body, card number, billing address, or customer email. Paddle receives and processes checkout, identity, payment, tax, receipt, and refund information as Merchant of Record under [Paddle's Privacy Notice](https://www.paddle.com/legal/privacy).

## 3. Update and reliability telemetry

Sparkle update checks pass through a Cloudflare Worker. For operational counts it may store the app version, user-agent string, country inferred by Cloudflare, and a salted daily hash derived from IP address, user agent, and app version. The hash rotates daily and is not designed to identify or track a person across days.

After a successful app start, DiskOUT may also send a random lifecycle installation UUID and event UUID over encrypted HTTPS with an event type (`first_launch`, `version_seen`, or verified `update_completed`), event time, current app version/build, and, when relevant, previous or intended target version/build. The Worker stores a secret-salted one-way hash of the lifecycle installation UUID rather than the raw UUID. This hash is stable so the service can prevent duplicate install/version/update counts; it is not derived from a disk, file, account, billing credential, IP address, or hardware identifier. Operational access returns aggregate counts only, not install hashes or event, transaction, customer, or per-user rows.

Anonymous crash and handled-error reporting is enabled by default and can be turned off in **DiskOUT Settings → General**. Reports contain only the app version, coarse macOS version, error category, crash type, and a scrubbed, size-limited stack trace. Before sending, DiskOUT removes home-directory usernames, mounted-volume names, temporary paths, and recognizable secret patterns. The reliability Worker may add country and the same kind of salted daily network hash. Disk names, file paths, file contents, and the billing recovery code are not included.

## 4. Purposes and service providers

We process this data only to provide and secure Premium access, prevent replay or unauthorized transfer, handle refunds and disputes, deliver software updates, estimate update health, diagnose failures, and support users. Service providers include:

- [Paddle](https://www.paddle.com/) for checkout, payment, tax, receipts, and refunds;
- [Cloudflare](https://www.cloudflare.com/privacypolicy/) for billing, update, and reliability infrastructure;
- [GitHub](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement) for source, releases, downloads, and support issues; and
- Apple/macOS for Keychain, notifications, code signing, and local diagnostic reports.

We do not sell personal data or use it for advertising.

## 5. Retention, security, and choices

Local app data remains until you delete the corresponding preferences, Application Support lifecycle state, or Keychain entries. Claim-attempt storage is limited to 1,000 records, and expired records are selected for deletion by an hourly cleanup job. Other billing records are retained as needed to honor a perpetual purchase, process refunds and disputes, prevent abuse, and meet legal or accounting duties. Operational telemetry is retained only for reliability and aggregate analysis. Access is limited and secrets are stored separately from public app configuration.

You can disable anonymous crash and error reports at any time. You may also submit an access, correction, or deletion request to [sukmack@gmail.com](mailto:sukmack@gmail.com) or through [DiskOUT Support](https://github.com/yooongZa/DiskOUT/issues). Some salted daily hashes cannot be linked back to a specific person, and some transaction records must be handled by Paddle or retained where required by law.

## 6. International processing and your rights

Paddle, Cloudflare, GitHub, and Apple may process data in countries other than yours under their respective terms and safeguards. Depending on your location, you may have rights to access, correct, delete, restrict, object to, or obtain a copy of personal data, and to complain to a data-protection authority. Mandatory rights are not limited by this policy.

## 7. Changes

We may update this policy as DiskOUT or its infrastructure changes. The effective date above identifies the current version.
