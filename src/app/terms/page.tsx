import type { Metadata } from "next";
import Link from "next/link";
import { ContactLink, LegalPage } from "../_components/LegalPage";

export const metadata: Metadata = {
  title: "नियम व शर्तें · Terms · PurohitDesk",
};

export default function TermsPage() {
  return (
    <LegalPage
      hindi={{
        title: "नियम व शर्तें",
        body: (
          <>
            <p>
              यह पुरोहित डेस्क का परीक्षण (टेस्ट) संस्करण है, जो केवल जाँच के लिए है। ये शर्तें अस्थायी हैं; ऐप शुरू
              होने से पहले पूरी शर्तें प्रकाशित की जाएँगी।
            </p>
            <p>
              ऐप जैसा है वैसा दिया जा रहा है। यह बिना सूचना के बदल सकता है, बंद हो सकता है, और इसका डेटा कभी भी मिटाया
              जा सकता है। कृपया इस पर किसी असली काम के लिए निर्भर न रहें।
            </p>
            <p>
              Google से साइन इन करके आप इन शर्तों और <Link href="/privacy" className="text-brand underline">गोपनीयता सूचना</Link>{" "}
              से सहमत होते हैं।
            </p>
            <p>
              संपर्क: <ContactLink />
            </p>
          </>
        ),
      }}
      english={{
        title: "Terms of use",
        body: (
          <>
            <p>
              This is a test version of PurohitDesk, for evaluation only. These terms are a placeholder; full terms
              will be published before launch.
            </p>
            <p>
              The app is provided as is. It may change or stop without notice, and its data may be deleted at any time.
              Please do not rely on it for real work.
            </p>
            <p>
              By signing in with Google you agree to these terms and the{" "}
              <Link href="/privacy" className="text-brand underline">privacy notice</Link>.
            </p>
            <p>
              Contact: <ContactLink />
            </p>
          </>
        ),
      }}
    />
  );
}
