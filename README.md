# AEC electorate postcodes

Which federal electorate(s) each Australian locality and postcode is in, scraped from the Australian Electoral Commission's [locality search](https://electorate.aec.gov.au/LocalitySearchResults.aspx).

It replaces [drzax/morph-division-postcode-correspondence](https://github.com/drzax/morph-division-postcode-correspondence) as the source for `parse-postcodes.rb` in [openaustralia-parser](https://github.com/openaustralia/openaustralia-parser), which loads the postcode lookup used by OpenAustralia.org.au and They Vote for You. See [openaustralia/openaustralia#1060](https://github.com/openaustralia/openaustralia/issues/1060).

## Data

The `data` table has one row for each locality and electorate. A locality split between electorates has a row for each of them.

| Column | Example | Notes |
|---|---|---|
| `state` | `NSW` | |
| `locality` | `CAMMERAY` | |
| `postcode` | `2062` | |
| `other_localities` | `ST LEONARDS` | Blank for most localities |
| `electorate` | `Bradfield` | |
| `electorate_type` | `current` | `redistributed` for the electorate a locality moves to at the next federal election, after a redistribution |

Each run replaces all the data, so abolished electorates don't linger. The run stops without saving if the data looks incomplete, for example when an electorate has no localities, keeping the previous run's data.

To get the postcode to electorate mapping that `parse-postcodes.rb` expects:

```sql
SELECT DISTINCT postcode, electorate FROM data WHERE electorate_type = 'current' ORDER BY postcode, electorate
```

## Running

```
bundle config set --local path vendor/bundle
bundle install
bundle exec ruby scraper.rb
```

A full run makes about 1,000 requests to `electorate.aec.gov.au`, one at a time, and takes about 5 minutes. Set `MORPH_AUSTRALIAN_PROXY` to send them through the Australian proxy.

## Testing

```
bundle exec rake
bundle exec rubocop
```

The specs use the saved AEC pages in `spec/fixtures/` and don't contact any site.

This is a scraper that runs on [morph.io](https://morph.io). To get started [see the documentation](https://morph.io/documentation).
