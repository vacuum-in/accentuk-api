# accentuk-api

> This repository is the **service**: stress API, lexicon database, model service, TTS frontend and UI, deployed with Docker.
> The offline **Python package** (`pip install accentuk`, no server needed) lives in [vacuum-in/accentuk](https://github.com/vacuum-in/accentuk).

**Stress marks for Ukrainian text-to-speech.** Given plain Ukrainian text,
it returns the same text with U+0301 after every stressed vowel, choosing
between the readings of heteronyms from context:

```
Замок на горі. Замок у дверях. Мої сестри.
Замо́к на горі́. Замо́к у́ две́рях. Мої́ се́стри.
```

The first замок is still wrong, and it shows the limit of a tagger and a
classifier on a sentence this short. See *Results* for how often that happens.

## What is here

| directory | what |
| --- | --- |
| [`wiki-stress/`](wiki-stress/) | the stress service: a PostgreSQL lexicon built from the Ukrainian Wiktionary dump and the `ukrainian-word-stress` dictionary (`etl/`); a Go HTTP API (`api/`) that looks every word up and asks the model service about the ambiguous ones; the model service and every training script (`ml/`) |
| [`uk-tts-frontend/`](uk-tts-frontend/) | a text frontend for TTS: numbers, dates and abbreviations spelled out by the [marian-uk-verbalizer](https://github.com/vacuum-in/marian-uk-verbalizer) span model ([E69 on Hugging Face](https://huggingface.co/aloudreader/marian-uk-verbalizer-spans-ct2-int8): it reads one span at a time and never rewrites the prose around it), then stress marked by the service above; Docker Compose deployment and a Gradio UI |
| [`audiotostress/`](audiotostress/) | the audio side: finds which vowel a narrator stressed, from aligned speech. Its labels trained the token classifier |
| [`model-cards/`](model-cards/) | the cards of the published models |

## Models

The trained models are on Hugging Face:

| model | role |
| --- | --- |
| [`aloudreader/uk-stress-crossencoder`](https://huggingface.co/aloudreader/uk-stress-crossencoder) | XLM-R cross-encoder: picks the sense of a homograph from its gloss |
| [`aloudreader/uk-stress-token-classifier`](https://huggingface.co/aloudreader/uk-stress-token-classifier) | XLM-R-uk classifier trained on stress heard in audiobooks: picks the stress of frequent ambiguous forms |
| [`aloudreader/uk-stress-combiner`](https://huggingface.co/aloudreader/uk-stress-combiner) | a small learned scorer over all tiers; off by default, `"combiner": true` per request |

A word goes through these tiers:
1. reviewed corrections;
2. the lexicon;
3. morphology (spaCy tagger and agreement rules);
4. the cross-encoder;
5. the token classifier;
6. the dictionary's default reading;
7. compound, suffix and positional fallbacks.

`wiki-stress/docs/architecture.md` and `wiki-stress/docs/state.md` have the details.

## Results

Measured on 2026-09-25 against the running service. Numbers are word accuracy.

| test | combiner off (default) | combiner on |
| --- | ---: | ---: |
| 200 most frequent ambiguous forms of Common Voice uk, stress heard in the recordings (13,201 tokens) | 95.88% | 97.27% |
| [lang-uk stress benchmark](https://github.com/lang-uk/ukrainian-tts-preprocessing), words / heteronyms | 95.92% / 84.62% | 96.02% / 85.28% |
| modern-text gold, 3,887 words | 98.07% | 97.27% |

On CPU a ~115-character line takes about 139 ms without the combiner and about 128 ms with it.

## Running it

On a Linux x86-64 host with Docker (compose v2), `curl`, `python3` and `unzip`, about 30 GB of free disk and 16 GB of RAM (no GPU needed):

```bash
git clone https://github.com/vacuum-in/accentuk-api && cd accentuk-api
uk-tts-frontend/deploy/install.sh
```

`install.sh` does the whole deployment:

1. It downloads the models from Hugging Face into `assets/` and the tagger `uk_core_news_trf` 3.8.0 from `explosion/spacy-models`.
2. It downloads the lexicon and its lookup tables from the [`data-v4` release](https://github.com/vacuum-in/accentuk-api/releases/tag/data-v4).
3. It builds the images and restores the lexicon into a fresh PostgreSQL volume.
4. It starts the stack, checks it, and stresses a probe sentence.

When it finishes, the stress API is on port 8080, the TTS frontend on 8000 and the UI on 7861:

```bash
curl -s -X POST http://127.0.0.1:8000/v1/prepare -H 'Content-Type: application/json' \
  -d '{"text": "О 7:45 ранку 3 квітня потяг № 12 прибув до Львова."}'
```

To run a second stack beside the first, set `COMPOSE_PROJECT_NAME`, `POSTGRES_VOLUME`, `IMAGE_TAG` and the `*_PORT` variables before running `install.sh`. Settings live in `uk-tts-frontend/deploy/.env` (see `.env.example`). Restart with `uk-tts-frontend/deploy/restart.sh`: it checks that the manifest and the lexicon agree, and waits until every tier answers.

The API's `/health/ready` fails with `lexicon_incomplete` when the database lacks everyday words. That is the sign of the wrong lexicon, which would otherwise be served silently with a positional default stress.

The lexicon in the release is what the service reads. It includes the reviewed corrections, so the numbers above apply. To rebuild it from its sources instead, follow the quick start in [`wiki-stress/README.md`](wiki-stress/README.md). `wiki-stress/db/lexicon_archive.sh` exports and imports a lexicon as gzip CSV files.

The training corpora and test sets are not published.

## Licence

Apache-2.0 for the code in this repository (see `LICENSE`). The lexicon in the data release is built from these sources, which keep their own licences:
- the Ukrainian Wiktionary is CC BY-SA 4.0;
- `ukrainian-word-stress` is MIT;
- the lang-uk resources carry their own terms.

The model cards describe what each model was trained on.
