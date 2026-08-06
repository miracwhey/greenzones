import type { CapacitorConfig } from "@capacitor/cli";

const config: CapacitorConfig = {
  appId: "de.leonvalentin.greenzones",
  appName: "GreenZones",
  webDir: "dist",
  ios: {
    // WKWebView-Hintergrund (ohne '#') — hell; dunkel übernimmt html/CSS
    backgroundColor: "E8EAED",
    contentInset: "never",
  },
  plugins: {
    StatusBar: {
      overlaysWebView: true,
    },
    SplashScreen: {
      launchShowDuration: 0,
      backgroundColor: "#E8EAED",
    },
  },
};

export default config;
