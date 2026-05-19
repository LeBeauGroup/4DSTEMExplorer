                .onReceive(NotificationCenter.default.publisher(for: .fileLoaded)) { notification in
                   print("finished loading")
                }