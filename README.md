# tarbel-opendata

Mirrors the Belgian minfin TARBEL tariff extractions as GitHub Release assets, so they can be downloaded via plain HTTP without navigating the JSF portal at [eservices.minfin.fgov.be](https://eservices.minfin.fgov.be/extTariffBrowser/XmlExtractions).

## Release structure

Each month gets one release tagged `YYYY-MM` (e.g. `2026-05`):

| File pattern | Type | Published |
|---|---|---|
| `export-{date}-{date}.zip` | Full extraction | ~1st of month |
| `export-{date}_{date}-{date}.zip` | Daily delta | Every day |

## Downloading

Assets are publicly accessible without authentication:

```
https://github.com/rousseauxy/tarbel-opendata/releases/download/2026-05/export-20260501T000000-20260501T000500.zip
```

Or list available files for a month via the GitHub API:

```
https://api.github.com/repos/rousseauxy/tarbel-opendata/releases/tags/2026-05
```

## How it works

A GitHub Actions workflow (`sync.yml`) runs daily at **01:05 UTC** (~03:05 CEST), about an hour after minfin publishes at 00:05 CEST:

1. Fetches the list of assets already uploaded to this month's release
2. Downloads only new files from the minfin portal (skips already-uploaded ones)
3. Uploads new ZIPs to the `YYYY-MM` GitHub Release

The workflow can also be triggered manually with an optional **Force** flag to re-download all files for the current month.

## Source

Data source: Belgian Federal Public Service Finance  
Portal: https://eservices.minfin.fgov.be/extTariffBrowser/XmlExtractions
