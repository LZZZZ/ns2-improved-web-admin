import { render } from "preact";
import { applyTheme } from "./store/settings";
import { App } from "./ui/App";
import "./styles.css";

// Before the first render, so a light theme never flashes dark first.
applyTheme();

const root = document.getElementById("app");
if (!root) throw new Error("#app is missing from index.html");
render(<App />, root);
