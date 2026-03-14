ExUnit.start(exclude: [:integration], capture_log: true)

Mimic.copy(Mnemosyne.MockLLM)
Mimic.copy(Mnemosyne.MockEmbedding)
Mimic.copy(Sycophant)
Mimic.copy(Mnemosyne.GraphBackends.InMemory)
Mimic.copy(Mnemosyne.Notifier)
