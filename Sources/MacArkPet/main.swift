// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 MacArkPet contributors

import AppKit

let app = NSApplication.shared

app.delegate = MacArkPetApp.shared
app.setActivationPolicy(.regular)
app.run()
