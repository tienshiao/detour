import Foundation

/// A trimmed excerpt of AdGuard's URL Tracking filter (filter 17, the
/// uBlock Origin build at https://filters.adtidy.org/extension/ublock/filters/17.txt,
/// version 2.0.14.84 of 2026-11-13), used by `TrackingParameterFilterTests`
/// and by the TASK-329 runtime check. The lines are copied unchanged from the
/// list, one or two of each rule form it uses, plus the comments marked
/// `(Detour)`.
///
/// AdGuard URL Tracking filter: © AdGuard Software Ltd and the AdguardFilters
/// contributors, https://github.com/AdguardTeam/AdguardFilters, licensed under
/// GPL-3.0 (https://github.com/AdguardTeam/AdguardFilters/blob/master/LICENSE).
/// Detour does not bundle the list: the app downloads it at runtime.
nonisolated enum TrackingParameterFilterFixture {
    static let text = #"""
    [Adblock Plus 2.0]
    ! Title: AdGuard URL Tracking filter
    ! Description: Filter that enhances privacy by removing tracking parameters from URLs.
    ! Version: 2.0.14.84
    ! Homepage: https://github.com/AdguardTeam/AdGuardFilters
    ! License: https://github.com/AdguardTeam/AdguardFilters/blob/master/LICENSE
    ! (Detour) A trimmed excerpt for tests, not the whole list.
    !
    ! (Detour) Global names
    $removeparam=pjclid
    $removeparam=mc_eid
    $removeparam=gclid
    ! (Detour) Global regex: skipped
    $removeparam=/^at_custom/
    $removeparam=/^__s=[A-Za-z0-9]{6\,}/,domain=~univis.uni-erlangen.de|~univis.uni-bamberg.de|~univis.uni-luebeck.de|~univis.uni-kiel.de|~univis.th-koeln.de
    $domain=atlanticcouncil.org|digikey.com,removeparam=/^mkt_tok/
    ! (Detour) Per-site by domain=, with a wildcard TLD
    $removeparam=ro,domain=khb-tv.co.jp|kab.co.jp|kfb.co.jp|maidonanews.jp|ncctv.co.jp|yorozoonews.jp|news.ksb.co.jp
    $removeparam=asc_campaign,domain=aboutamazon.com|amazon.*|amzn.to
    *$removeparam=channable,domain=easynotebooks.de|notebook.de
    ! (Detour) Per-site by URL pattern
    ||supply.amazon.com^$removeparam=ref_
    ||amazon.*/stores/$removeparam=lp_asin
    ||audible.*/series/$removeparam=ref
    ||luna.amazon.*^$removeparam=ref
    ||read.amazon.$removeparam=ref
    ||x.com^$removeparam=s
    ||youtube.com/shorts/$removeparam=si
    ||check24.de/suche/?q$removeparam=source
    ||reddit.com^$removeparam=%243p
    ||wetransfer.com^$removeparam=amp;utm_campaign
    ||bandsintown.com^$removeparam=app_id,document
    ||sell.amazon.de^$removeparam=refTag
    ! (Detour) Substring patterns, remove-all and keep-only
    &af_xp=$removeparam=c
    ?from=glia^$removeparam=from
    rtkcid=*&clickid=$removeparam=clickid
    /?affijet-click=$removeparam
    ||go.mysku.ru^$removeparam=~r
    ! (Detour) Other request types, regex values: skipped
    ||alia-cloudflare.com/launcher/$removeparam=ip_address,xhr
    ||use.typekit.net^$font,removeparam=~/^(primer|subset_id)=/,domain=~fonts.adobe.com
    ||ad.doubleclick.net/ddm/clk/$removeparam=/^\\$ja=/
    ||chaturbate.com^$removeparam=/tour|campaign/,~3p
    ! (Detour) Not a $removeparam rule
    adguard.info,adguard.com,adguard.app##.hello_from_adguard_tracking_params
    ! (Detour) Exceptions
    @@||archive.*^$removeparam
    @@||eneba.com^$removeparam=utm_source
    @@$removeparam=utm_source,domain=hobbygames.ru
    @@||google.*/maps^$removeparam=utm_campaign
    @@||3dnews.ru/*?utm_source=^$removeparam=utm_source
    @@||greenbuildingadvisor.com^$removeparam=oly_enc_id
    @@||msn.com^$app=msedgewebview2.exe,removeparam=ocid
    @@||rpc.meituan.com/api/foodorder$removeparam,xhr,domain=awp.meituan.com
    """#
}
