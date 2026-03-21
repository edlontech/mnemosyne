# Changelog

## [0.1.2](https://github.com/edlontech/mnemosyne/compare/mnemosyne-v0.1.1...mnemosyne-v0.1.2) (2026-03-21)


### Features

* add async session operations with pending ops queue ([583225c](https://github.com/edlontech/mnemosyne/commit/583225c6d14c70251687709fc27406f90d4e2b4d))
* Added Append Async function with improved concurrency ([ebe74c6](https://github.com/edlontech/mnemosyne/commit/ebe74c63ba0dec4c7cf8f80ac50fa8f41cae0f3f))
* Added function to fetch the latest top_k results ([fcfbacb](https://github.com/edlontech/mnemosyne/commit/fcfbacb6aaed1fc94b2c610e0fd1b523825a7f97))
* conditional per-hop query refinement in retrieval ([161d4f4](https://github.com/edlontech/mnemosyne/commit/161d4f4c93dd8d200ee416af1fe90b94372540d4))
* include node_ids in trajectory_committed/flushed events ([01e341b](https://github.com/edlontech/mnemosyne/commit/01e341b1d9571e169d71fb2f7fc46d8d9cd71e4a))
* incremental session commit with auto-commit and idle timeouts ([a5a3f6d](https://github.com/edlontech/mnemosyne/commit/a5a3f6d0a6692460e1db542d8ecf4b8852e99653))
* lazy progressive state derivation at extraction time ([70cdb21](https://github.com/edlontech/mnemosyne/commit/70cdb21a99f95be81190f58ec1b0d9c781ae09f1))
* notifier observability with trace structs and metadata ([c9c81ba](https://github.com/edlontech/mnemosyne/commit/c9c81ba15dd4aa31c1549e3a03290de5ed5514e7))
* per-prescription return scores in structuring pipeline ([7ae3fc4](https://github.com/edlontech/mnemosyne/commit/7ae3fc4545c43eddc27cbcfa86c216d693f520a5))
* tag normalization and deduplication in write lane ([3770a5c](https://github.com/edlontech/mnemosyne/commit/3770a5c396c6f03810fffe96aec3e6e82856f999))
* update access metadata on retrieval ([9d0c5af](https://github.com/edlontech/mnemosyne/commit/9d0c5af5f67f2395759ed281ec07554b34e9c253))


### Bug Fixes

* Emits extracting-&gt;idle on auto-commit ([b9b60b6](https://github.com/edlontech/mnemosyne/commit/b9b60b6403f0aebba2ca3a5a3ff4aa0eb1cbce71))
* Fixed provenance edges connection ([563db7e](https://github.com/edlontech/mnemosyne/commit/563db7e4fed175fc4db497cdc7e48fba3b071ee1))
* Fixed race condition in the notifier ([464a1ec](https://github.com/edlontech/mnemosyne/commit/464a1ec13db0bd728f013f634ddbb8ab10a62018))
* Track committed step indices instead of trajectory IDs in auto-commit ([17714ce](https://github.com/edlontech/mnemosyne/commit/17714ceca24348c27542a1a7f963f0afa9cabbf1))

## [0.1.1](https://github.com/edlontech/mnemosyne/compare/mnemosyne-v0.1.0...mnemosyne-v0.1.1) (2026-03-17)


### Features

* add two-lane async queue to MemoryStore for concurrent writes and maintenance ([14eedd4](https://github.com/edlontech/mnemosyne/commit/14eedd4c436445a193fe9cc35a609932446476ae))


### Bug Fixes

* Fixed dialyzer and silent errors ([268dc69](https://github.com/edlontech/mnemosyne/commit/268dc69dbaa4dc257dd8c9ed0479fa34b1521374))

## [0.1.0](https://github.com/edlontech/mnemosyne/compare/mnemosyne-v0.0.1...mnemosyne-v0.1.0) (2026-03-15)


### Features

* add adapter integration tests for SycophantLLM and BumblebeeEmbedding ([9a6004d](https://github.com/edlontech/mnemosyne/commit/9a6004d80e4d2c2c7649d828aea169486471749b))
* add concept/intent hierarchy with structured LLM extraction ([89e5c08](https://github.com/edlontech/mnemosyne/commit/89e5c08520f8cf4dfd5a4608e63813b81cc444bc))
* add full lifecycle integration test ([267a334](https://github.com/edlontech/mnemosyne/commit/267a33483ff75ba587785f767ac98b07fab0a8fb))
* add integration test CaseTemplate with Bumblebee/OpenRouter setup ([ae442cb](https://github.com/edlontech/mnemosyne/commit/ae442cbfc418e6600954f0f9996ac45621b9a676))
* add intent merging pipeline for deduplication ([4b50215](https://github.com/edlontech/mnemosyne/commit/4b5021528a80ebff6bb7d4160eeddf71474fde96))
* add Layer 1 data primitives (graph, nodes, behaviours, value functions) ([be3b1db](https://github.com/edlontech/mnemosyne/commit/be3b1db68e654d5e0de9485404e34f8d2a1ebf1e))
* add LLM adapter, unified config, and Sycophant integration ([2795346](https://github.com/edlontech/mnemosyne/commit/27953468381e416260dc0edc0d1c8fdde1d301d5))
* add OTP runtime with supervisor tree, session lifecycle, and public API ([57c95cf](https://github.com/edlontech/mnemosyne/commit/57c95cf8b4d390387db3526d12785508c375e296))
* add retrieval and reasoning pipeline ([6e0c593](https://github.com/edlontech/mnemosyne/commit/6e0c593569174e9ee53c3917d40d199e83a85f87))
* add structuring pipeline with episode tracking and knowledge extraction ([e7fd568](https://github.com/edlontech/mnemosyne/commit/e7fd56827501b658e73cab3aa7cecc465c21975a))
* add telemetry and structured logging ([1225ed4](https://github.com/edlontech/mnemosyne/commit/1225ed47731028efd07bb24343aa21ee44643bb6))
* Added Bumblebee Embedding adapter ([3becb3f](https://github.com/edlontech/mnemosyne/commit/3becb3f3f1288a0433c39b8c50e9695a8e09c467))
* Added integration tests ([e993728](https://github.com/edlontech/mnemosyne/commit/e993728705918717b2f4ac4c7f67b7f5c2bc1865))
* extend telemetry with maintenance events and repo_id metadata ([0e177b1](https://github.com/edlontech/mnemosyne/commit/0e177b10136bdb82893aa05a078246b864b1c6ce))
* graph maintenance - sibling links, semantic consolidation, and decay pruning ([02ca145](https://github.com/edlontech/mnemosyne/commit/02ca14571af09e7d9c9bb28c79598ec6f00062b8))
* implement abstraction-specificity interleaving in retrieval ([893f2e5](https://github.com/edlontech/mnemosyne/commit/893f2e5d1e36cdbb96589f2a3888fce4f03cc299))
* implement real value function scoring with metadata ([f8d5256](https://github.com/edlontech/mnemosyne/commit/f8d5256577db4f8dfdb1c9deb92c0e1e2f4fbd9c))
* multi-repo isolation with lifecycle API ([d6a139a](https://github.com/edlontech/mnemosyne/commit/d6a139aa354deacafc83c76b536c45939ef5775d))
* notifier behaviour with real-time graph events and node query API ([4af4ed1](https://github.com/edlontech/mnemosyne/commit/4af4ed110f8e580497fd957a5748e52eabaa3ad6))
* replace bare atom errors with Splode error structs ([8d735bc](https://github.com/edlontech/mnemosyne/commit/8d735bc4a988559450f10c764605e783104beb08))


### Bug Fixes

* convert integration helpers to plain module with public API ([e98d318](https://github.com/edlontech/mnemosyne/commit/e98d318b81e65189a3a09c02fbfd1bb6fe27e731))
* remove double charlist conversion, inline import, clarify error message ([d64bd34](https://github.com/edlontech/mnemosyne/commit/d64bd349b9b464b19981cc7979f580be299ab35b))
* split adapter tests, fix model prefix, add timeouts ([124ecc9](https://github.com/edlontech/mnemosyne/commit/124ecc90f383c406d51b4166b382bd37e359910b))
* strengthen lifecycle test assertions ([6707017](https://github.com/edlontech/mnemosyne/commit/6707017af5db76354a6468b37211ea5651c91947))
* use separate [@moduletag](https://github.com/moduletag) declarations instead of list ([b2b8487](https://github.com/edlontech/mnemosyne/commit/b2b84874a9cbc9a4b5fdfdf235471c537e24f5eb))


### Continuous Integration

* Fixed release-action ([c553ada](https://github.com/edlontech/mnemosyne/commit/c553ada943c4694c0ade77b18e92817bdc842595))
