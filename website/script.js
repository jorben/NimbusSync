(() => {
    const button = document.querySelector("#language");
    const textNodes = [...document.querySelectorAll("[data-en]")];
    const ariaNodes = [...document.querySelectorAll("[data-en-aria]")];
    const images = [...document.querySelectorAll("[data-en-src]")];
    const titles = {
        "zh-CN": "NimbusSync — 你的 Cloudreve，就在 Finder。",
        en: "NimbusSync — Your Cloudreve. Right in Finder.",
    };

    // Preserve the complete Chinese document as the no-JavaScript fallback.
    textNodes.forEach((node) => { node.dataset.zh = node.innerHTML; });
    ariaNodes.forEach((node) => { node.dataset.zhAria = node.getAttribute("aria-label"); });
    images.forEach((node) => { node.dataset.zhAlt = node.alt; });

    function setLanguage(language) {
        const english = language === "en";
        document.documentElement.lang = language;
        document.title = titles[language];
        textNodes.forEach((node) => {
            if (english) node.textContent = node.dataset.en;
            else node.innerHTML = node.dataset.zh;
        });
        ariaNodes.forEach((node) => {
            node.setAttribute("aria-label", english ? node.dataset.enAria : node.dataset.zhAria);
        });
        images.forEach((node) => {
            node.src = english ? node.dataset.enSrc : node.dataset.zhSrc;
            node.alt = english ? node.dataset.enAlt : node.dataset.zhAlt;
        });
        button.textContent = english ? "简体中文" : "English";
        button.lang = english ? "zh-CN" : "en";
        button.setAttribute("aria-label", english ? "切换为简体中文" : "Switch to English");
        const url = new URL(window.location.href);
        if (english) url.searchParams.set("lang", "en");
        else url.searchParams.delete("lang");
        window.history.replaceState(null, "", url);
    }

    const requested = new URLSearchParams(window.location.search).get("lang");
    setLanguage(requested === "en" ? "en" : "zh-CN");
    button.hidden = false;
    button.addEventListener("click", () => {
        setLanguage(document.documentElement.lang === "en" ? "zh-CN" : "en");
    });
})();
