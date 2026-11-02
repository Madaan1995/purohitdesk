import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { SiteFooter } from "@/app/_components/SiteFooter";
import PrivacyPage from "@/app/privacy/page";
import TermsPage from "@/app/terms/page";

const render = (page: () => React.ReactElement) => renderToStaticMarkup(createElement(page));

describe("public legal pages", () => {
  it.each([
    ["privacy", PrivacyPage, "गोपनीयता सूचना", "Privacy notice"],
    ["terms", TermsPage, "नियम व शर्तें", "Terms of use"],
  ])("/%s renders Hindi and English with the contact email", (_name, page, hindi, english) => {
    const html = render(page);
    expect(html).toContain(hindi);
    expect(html).toContain(english);
    expect(html).toContain("mailto:amanmadaan87@gmail.com");
    expect(html).toContain("test version");
  });

  it("privacy notice names the data collected from Google", () => {
    expect(render(PrivacyPage)).toContain("name and email address");
  });

  it("site footer (home and sign-in pages) links both pages", () => {
    const html = render(SiteFooter);
    expect(html).toContain('href="/privacy"');
    expect(html).toContain('href="/terms"');
  });
});
