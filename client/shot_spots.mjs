import { chromium } from "playwright";

// usage: node shot_spots.mjs <url> <out.png> <map|newspot|pick|detail|solo|invite|sent|manage|reply|friends|profile|profile-empty|welcome> [dark]
// profile = Editor aus der Freundesliste · profile-empty = Liste ohne eigenes Profil
// welcome = der Profil-Schritt nach einem Beitritt (Freunde da, eigener Name leer)
// solo = Leons Erstnutzer-Fall: 0 Freunde, lokaler Spot → Detail muss in den
// Freund-einladen-Flow führen (keine Sackgasse).
// Screenshots des Community-Features. Der Bestand kommt als Fixture in den
// Storage, den die App wirklich liest (Capacitor Preferences → localStorage
// unter "CapacitorStorage.<key>"); gerendert wird danach der echte App-Pfad.
const [url, out, scenario = "map", ...flags] = process.argv.slice(2);
const dark = flags.includes("dark");

const browser = await chromium.launch();
const context = await browser.newContext({
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 2,
  colorScheme: dark ? "dark" : "light",
  // Hannover-Mitte — die Fixture-Spots liegen im selben Ausschnitt.
  geolocation: { longitude: 9.7386, latitude: 52.3728 },
  permissions: ["geolocation"],
  locale: "de-DE",
  timezoneId: "Europe/Berlin",
});
const page = await context.newPage();
page.on("pageerror", (e) => console.error("[pageerror]", e.message));
page.on("console", (m) => {
  if (m.type() === "error" && !m.text().includes("GL Driver")) console.error("[console]", m.text());
});

await page.addInitScript((s) => {
  // Zeiten relativ zu „jetzt": der nächste 20-Uhr-Abend, der noch mindestens
  // eine Stunde entfernt ist — sonst hinge das Bild an der Uhrzeit des Laufs.
  const now = Date.now();
  const evening = new Date(now);
  evening.setHours(20, 0, 0, 0);
  if (evening.getTime() < now + 3600000) evening.setDate(evening.getDate() + 1);
  const t20 = evening.getTime();
  const t21 = t20 + 3600000;

  // Beide Spots müssen bei Startzoom (14.2 ≈ 2,54 m/px) neben dem Puck ins
  // Bild passen — sonst zeigt „map" nur einen halben Marker am Rand.
  // s1 ist geteilt (zoneName → „Einladen"-CTA), s2 bleibt lokal („Mit
  // Freunden teilen") — beide Welten sichtbar. Ohne zoneName gäbe es den
  // Einladen-Pfad der Szenarien invite/sent gar nicht mehr.
  const spots = [
    { id: "s1", name: "Unsere Bank", emoji: "🪑", lng: 9.7354, lat: 52.3733, createdAt: now - 86400000,
      zoneName: "spot-s1", participantIds: ["f1", "f2"], shareURL: "https://www.icloud.com/share/s1" },
    { id: "s2", name: "Maschsee-Ecke", emoji: "🌳", lng: 9.7408, lat: 52.3693, createdAt: now - 43200000 },
  ];
  // Marcel hat ein Zeichen, Tara nicht — beide Avatar-Fälle stehen so im Bild.
  const friends = [
    { id: "f1", name: "Marcel", emoji: "🎧", color: "#7C5CFF", friendshipZone: "friend-f1" },
    { id: "f2", name: "Tara", color: "#0A9B8E", friendshipZone: "friend-f2" },
  ];
  const invitation = (extra) => [
    { id: "i1", spotId: "s1", hostId: "me", time: t20, createdAt: now - 3600000, cancelled: false, replies: [], ...extra },
  ];

  let invites = [];
  if (s === "map") invites = invitation({});
  if (s === "manage") {
    invites = invitation({
      replies: [
        { participantId: "f1", status: "in" },
        { participantId: "f2", status: "in", arrivalTime: t21 },
      ],
    });
  }
  // Fremde Einladung, eigene Antwort fehlt → Antwortraum des Empfängers.
  if (s === "reply") invites = invitation({ hostId: "f1", replies: [{ participantId: "f2", status: "in" }] });

  localStorage.setItem("gz_onboarded", "1");
  // Das eigene Profil ist der Prüfling: „welcome" und „profile-empty" laufen
  // bewusst OHNE Namen, damit der leere Zustand echt ist und nicht gestellt.
  if (s !== "welcome" && s !== "profile-empty") {
    localStorage.setItem("CapacitorStorage.gz_display_name", "Leon");
    localStorage.setItem("CapacitorStorage.gz_profile_emoji", "🌿");
  }
  // „profile-empty" ist der Zustand NACH dem Überspringen: der Schritt ruht,
  // die Liste trägt den offenen Hinweis. Ohne das Flag läge der Schritt davor.
  if (s === "profile-empty") localStorage.setItem("CapacitorStorage.gz_profile_asked", "1");
  if (s === "solo") {
    localStorage.setItem("CapacitorStorage.gz_spots", JSON.stringify([spots[1]]));
    localStorage.setItem("CapacitorStorage.gz_invites", "[]");
    localStorage.setItem("CapacitorStorage.gz_friends", "[]");
  } else {
    localStorage.setItem("CapacitorStorage.gz_spots", JSON.stringify(spots));
    localStorage.setItem("CapacitorStorage.gz_invites", JSON.stringify(invites));
    localStorage.setItem("CapacitorStorage.gz_friends", JSON.stringify(friends));
  }
}, scenario);

await page.goto(url);
await page.waitForFunction(() => window.__MAP_READY__ === true, null, { timeout: 30000 });
await page.waitForTimeout(1500);

const openSpot = async (name) => {
  await page.click(`button[aria-label="Spot ${name}"]`);
  await page.waitForTimeout(700);
};

if (scenario === "newspot" || scenario === "pick") {
  await page.click(".fab.sp-add");
  await page.waitForTimeout(600);
  await page.fill(".sp-field input", "Unsere Bank");
  await page.waitForTimeout(400);
  if (scenario === "pick") {
    await page.click(".sp-seg button:nth-child(2)");
    await page.waitForTimeout(600);
  }
} else if (scenario === "detail" || scenario === "manage" || scenario === "reply") {
  await openSpot("Unsere Bank");
} else if (scenario === "solo") {
  await openSpot("Maschsee-Ecke");
} else if (scenario === "invite" || scenario === "sent") {
  await openSpot("Unsere Bank");
  await page.click(".detail .sp-cta.blue");
  await page.waitForTimeout(700);
  if (scenario === "sent") {
    // Geteilte Spots schreiben CK-first; im Browser läuft der Web-Stub →
    // dieses Szenario zeigt den EHRLICHEN ABBRUCH (Toast, Sheet bleibt offen,
    // Store unverändert). Der Erfolgspfad ist nur auf Gerät/Sim mit iCloud real.
    await page.click(".detail .sp-cta.blue");
    await page.waitForTimeout(900);
  }
} else if (scenario === "friends" || scenario === "profile-empty" || scenario === "profile") {
  await page.click('.fab[aria-label="Freunde"]');
  await page.waitForTimeout(700);
  if (scenario === "profile") {
    await page.click(".sp-self");
    await page.waitForTimeout(600);
  }
} else if (scenario === "welcome") {
  // Kein Klick: der Schritt kommt von selbst, sobald Freunde da sind und das
  // eigene Profil fehlt. Genau das soll das Bild belegen.
  await page.waitForTimeout(900);
}

await page.screenshot({ path: out });
await browser.close();
console.log("written:", out);
