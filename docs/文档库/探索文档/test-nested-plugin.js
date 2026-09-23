// 问题插件的复现版本 - 使用嵌套注册方式
window.__ModuleLoader__.load({
  id: "@userlocal/test-nested-plugin",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;
    Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
    
    const inject = ['slots'];
    
    function apply(ctx) {
      // 问题方式: 嵌套调用 inject 和 register
      ctx.slots.inject(
        'sidebar.footer.action',
        () => ctx.slots.register(
          {
            name: 'sidebar.footer.action',
            id: 'test-nested-button',
            order: 20,
            locale: 'testNested'
          },
          function TestNestedButton(props) {
            const { wide } = props || {};
            return React.createElement('div', null, 
              React.createElement('button', {
                onClick: () => alert('Nested Button clicked!'),
                style: {
                  width: '36px',
                  height: '36px',
                  borderRadius: '50%',
                  background: 'red',
                  color: 'white',
                  border: 'none',
                  cursor: 'pointer'
                }
              }, '🔴')
            );
          }
        )
      );
    }
    
    exports.apply = apply;
    exports.inject = inject;
    return module.exports;
  }
});
