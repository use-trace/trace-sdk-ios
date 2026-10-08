# Changelog

Each release is also a GitHub release, with its pull request's description as the notes.

## 0.3.0, not yet released

- On a consent gated site (UK and EU, or no region set) the SDK no longer registers the install with Apple
  (SKAdNetwork, AdAttributionKit) or writes `install_registered` and `conversion_value` before the person says yes.
  A yes registers the install and sets the value, including from conversions made earlier in that launch.
- Apple's conversion value is never set for someone who said no. A refusal or a withdrawal stops it and removes both
  Apple files, in every region. A later yes registers the install again.
- On a US or Other site the install is still registered at first launch, unless the answer the app passes at launch
  is a no.
- The SDK asks Trace at launch whether the site is consent gated (`GET /v1/snippet-config`), as the website tag does,
  and keeps the answer only when it is "not gated" (`site_not_consent_gated`). No answer reads as gated.
- That Trace has counted the install's first consent answer is kept in an empty `answer_reported` file, written after
  the answer, instead of in the `conversion_value` record. A 0.2.0 record's answer is still read.
- Effect: on a UK or EU site Apple reports only the installs of people who said yes. Decided by Dom on 8 October 2026
  after legal advice (PECR regulation 6, ePrivacy article 5(3)).

## 0.2.0, 7 October 2026

- Trace's conversion value schema, version 1, and the platform and first answer on the consent call.

## 0.1.1, 7 October 2026

- Events go to `https://app.usetrace.io/api-proxy`; 0.1.0 sent them to the dashboard's address, where they were lost.

## 0.1.0, 6 October 2026

- First release.
