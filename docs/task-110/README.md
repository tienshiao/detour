# TASK-110 website capture kit (moved)

The capture kit now lives in [`docs/capture`](../capture/README.md)
(TASK-228.3). The DemoStage harness and its AppDelegate hook patch were
retired: the demo world is a fixture seeded through the automation endpoint
(`seed_world`), the window is placed with `set_window_frame`, and Debug UI
comes up with `open_ui`, so a capture needs no app patch. Their last versions
are in git history (`git show ab3c3fb:docs/task-110/DemoStage.swift.txt`).
