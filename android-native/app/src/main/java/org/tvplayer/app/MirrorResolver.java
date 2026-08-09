package org.tvplayer.app;

import java.net.URI;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;

/**
 * 国内可达镜像扩展：把 GitHub 系地址展开为一组候选 URL（调用方并发竞速，任一可达即成功）。
 * 与 iOS MirrorResolver.swift 逻辑对齐：
 * - `*.github.io` Pages：原址优先，再补 jsDelivr / ghproxy / raw
 * - `raw.githubusercontent.com`：大陆基本被墙，镜像优先、raw 殿后
 * - `cdn.jsdelivr.net` / `fastly.jsdelivr.net`：CDN 延迟时回退 Pages 与 raw
 * - 其他地址：原样返回，不做展开
 */
public final class MirrorResolver {
    private MirrorResolver() {}

    /** jsDelivr 公共 CDN（大陆一般可直连；@分支 缓存约 12 小时） */
    private static final String[] JSDELIVR_HOSTS = {
            "https://fastly.jsdelivr.net/gh/",
            "https://cdn.jsdelivr.net/gh/",
    };

    /** ghproxy 类网关（时有失效，仅作兜底） */
    private static final String[] GHPROXY_PREFIXES = {
            "https://gh-proxy.com/",
    };

    /** 返回去重后的候选列表；无法识别的地址返回 [原址] */
    public static List<String> candidates(String urlString) {
        String url = urlString == null ? "" : urlString.trim();
        if (url.isEmpty()) {
            return new ArrayList<>();
        }
        List<String> list = new ArrayList<>();

        RawGithub raw = parseRawGitHub(url);
        if (raw != null) {
            for (String host : JSDELIVR_HOSTS) {
                list.add(host + raw.user + "/" + raw.repo + "@" + raw.branch + "/" + raw.path);
            }
            for (String prefix : GHPROXY_PREFIXES) {
                list.add(prefix + url);
            }
            list.add(url);
        } else {
            Pages pages = parseGitHubPages(url);
            if (pages != null) {
                list.add(url);
                // Pages 通常发布自默认分支，按 main 推断补镜像（猜错只是多一个失败候选）
                for (String host : JSDELIVR_HOSTS) {
                    list.add(host + pages.user + "/" + pages.repo + "@main/" + pages.path);
                }
                String rawUrl = "https://raw.githubusercontent.com/" + pages.user + "/"
                        + pages.repo + "/main/" + pages.path;
                for (String prefix : GHPROXY_PREFIXES) {
                    list.add(prefix + rawUrl);
                }
                list.add(rawUrl);
            } else {
                JsDelivr cdn = parseJSDelivr(url);
                if (cdn != null) {
                    // CDN 源容错：jsDelivr 延迟/限流时，回退同文件的 Pages 与 raw
                    list.add(url);
                    list.add("https://" + cdn.user + ".github.io/" + cdn.repo + "/" + cdn.path);
                    String rawUrl = "https://raw.githubusercontent.com/" + cdn.user + "/"
                            + cdn.repo + "/" + cdn.branch + "/" + cdn.path;
                    for (String prefix : GHPROXY_PREFIXES) {
                        list.add(prefix + rawUrl);
                    }
                    list.add(rawUrl);
                } else {
                    list.add(url);
                }
            }
        }

        // 去重保序
        LinkedHashSet<String> seen = new LinkedHashSet<>(list);
        return new ArrayList<>(seen);
    }

    // raw.githubusercontent.com/<user>/<repo>/<branch>/<path>
    private static RawGithub parseRawGitHub(String url) {
        try {
            URI u = new URI(url);
            String host = u.getHost();
            if (host == null || !host.equals("raw.githubusercontent.com")) {
                return null;
            }
            String[] parts = u.getPath().split("/");
            if (parts.length < 5) { // 首元素为空串
                return null;
            }
            StringBuilder path = new StringBuilder();
            for (int i = 4; i < parts.length; i++) {
                if (path.length() > 0) path.append('/');
                path.append(parts[i]);
            }
            return new RawGithub(parts[1], parts[2], parts[3], path.toString());
        } catch (Exception e) {
            return null;
        }
    }

    // <user>.github.io/<repo>/<path>
    private static Pages parseGitHubPages(String url) {
        try {
            URI u = new URI(url);
            String host = u.getHost();
            if (host == null || !host.endsWith(".github.io")) {
                return null;
            }
            String user = host.substring(0, host.length() - ".github.io".length());
            if (user.isEmpty() || user.contains(".")) {
                return null;
            }
            String[] parts = u.getPath().split("/");
            if (parts.length < 3) { // 首元素为空串，至少 repo + path
                return null;
            }
            StringBuilder path = new StringBuilder();
            for (int i = 2; i < parts.length; i++) {
                if (path.length() > 0) path.append('/');
                path.append(parts[i]);
            }
            return new Pages(user, parts[1], path.toString());
        } catch (Exception e) {
            return null;
        }
    }

    // cdn.jsdelivr.net/gh/<user>/<repo>@<branch>/<path>
    private static JsDelivr parseJSDelivr(String url) {
        try {
            URI u = new URI(url);
            String host = u.getHost();
            if (host == null || (!host.equals("cdn.jsdelivr.net") && !host.equals("fastly.jsdelivr.net"))) {
                return null;
            }
            String[] parts = u.getPath().split("/");
            if (parts.length < 5 || !parts[1].equals("gh")) { // 首元素为空串
                return null;
            }
            String[] repoParts = parts[3].split("@", 2);
            if (repoParts.length != 2) {
                return null;
            }
            StringBuilder path = new StringBuilder();
            for (int i = 4; i < parts.length; i++) {
                if (path.length() > 0) path.append('/');
                path.append(parts[i]);
            }
            return new JsDelivr(parts[2], repoParts[0], repoParts[1], path.toString());
        } catch (Exception e) {
            return null;
        }
    }

    private static final class RawGithub {
        final String user, repo, branch, path;
        RawGithub(String user, String repo, String branch, String path) {
            this.user = user; this.repo = repo; this.branch = branch; this.path = path;
        }
    }

    private static final class Pages {
        final String user, repo, path;
        Pages(String user, String repo, String path) {
            this.user = user; this.repo = repo; this.path = path;
        }
    }

    private static final class JsDelivr {
        final String user, repo, branch, path;
        JsDelivr(String user, String repo, String branch, String path) {
            this.user = user; this.repo = repo; this.branch = branch; this.path = path;
        }
    }
}
