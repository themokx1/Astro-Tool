import LibA
@MainActor func makeInApp() -> Store { Store() }
@MainActor func makeInApp2() -> NonIsolatedDefault { NonIsolatedDefault() }
func makeInApp3() -> NoActor { NoActor() }
print(await makeInApp().use(), makeInApp2(), makeInApp3())
@MainActor func makeInApp4() -> OptionalDefault { OptionalDefault() }
print(await makeInApp4().use())
