import AppBoxCore

extension LibraryService {
    /// 生产环境的端口装配。
    ///
    /// 覆盖层与控制台共用同一个实例：否则两边各持一份图标缓存状态，
    /// 一边刚补好的图标另一边看不见。
    static func live() -> LibraryService {
        LibraryService(
            scanner: AppScanner(),
            icons: CachedIcons(
                cache: IconCache(directory: AppBoxIdentity.iconsDirectory),
                renderer: SystemIconRenderer()
            ),
            launcher: WorkspaceLauncher()
        )
    }
}
