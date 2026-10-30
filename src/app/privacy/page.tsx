import type { Metadata } from "next";
import { ContactLink, LegalPage } from "../_components/LegalPage";

export const metadata: Metadata = {
  title: "गोपनीयता · Privacy · PurohitDesk",
};

export default function PrivacyPage() {
  return (
    <LegalPage
      hindi={{
        title: "गोपनीयता सूचना",
        body: (
          <>
            <p>
              यह पुरोहित डेस्क का परीक्षण (टेस्ट) संस्करण है। यह सूचना अस्थायी है; ऐप शुरू होने से पहले पूरी
              गोपनीयता सूचना प्रकाशित की जाएगी।
            </p>
            <p>
              जब आप Google से साइन इन करते हैं, तो हम आपके Google खाते से केवल आपका नाम और ईमेल पता लेते हैं। इनका
              उपयोग आपको पहचानने और आपका खाता चलाने के लिए होता है। हम यह जानकारी बेचते नहीं हैं।
            </p>
            <p>
              टेस्ट संस्करण का डेटा कभी भी मिटाया या बदला जा सकता है। कृपया इसमें असली ग्राहकों की जानकारी न डालें।
            </p>
            <p>
              प्रश्न या अपना डेटा हटवाने के लिए संपर्क करें: <ContactLink />
            </p>
          </>
        ),
      }}
      english={{
        title: "Privacy notice",
        body: (
          <>
            <p>
              This is a test version of PurohitDesk. This notice is a placeholder; a full privacy notice will be
              published before launch.
            </p>
            <p>
              When you sign in with Google, we receive only your name and email address from your Google account. We
              use them to identify you and run your account. We do not sell this information.
            </p>
            <p>Data in the test version may be deleted or reset at any time. Please do not enter real customer details.</p>
            <p>
              For questions, or to have your data deleted, contact: <ContactLink />
            </p>
          </>
        ),
      }}
    />
  );
}
