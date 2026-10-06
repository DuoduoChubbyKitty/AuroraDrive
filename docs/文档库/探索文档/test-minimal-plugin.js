// 最小化测试插件 - 测试 sidebar.footer.action slot 注册
window.__ModuleLoader__.load({
  id: "@userlocal/test-minimal-plugin",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;
    Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
    
    // 只需要 slots 服务
    const inject = ['slots'];
    
    function apply(ctx) {
      // 方式1: 直接注册（参考 dsh-client-ui-jobs 的做法）
      ctx.slots.inject("sidebar.footer.action", () => ctx.slots.register({
        name: "sidebar.footer.action",
        id: "test-minimal-button",
        order: 10,
        locale: "testMinimal"
      }, function TestButton(props) {
        const { wide } = props || {};
        return React.createElement('button', {
          onClick: () => alert('Button clicked!'),
          style: {
            width: wide ? '100%' : '36px',
            minHeight: wide ? '40px' : '36px',
            padding: wide ? '8px 12px' : '0',
            fontSize: '13px',
            color: 'var(--dsw-alias-label-secondary)',
            background: 'transparent',
            border: 'none',
            borderRadius: wide ? '8px' : '50%',
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            justifyContent: wide ? 'flex-start' : 'center',
            gap: '8px',
            transition: 'all 0.15s ease'
          }
        }, 
          React.createElement('span', { style: { fontSize: '18px' } }, '🧪'),
          wide && React.createElement('span', null, '测试')
        );
      }));
    }
    
    exports.apply = apply;
    exports.inject = inject;
    return module.exports;
  }
});
