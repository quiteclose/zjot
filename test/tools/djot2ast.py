import json,sys,subprocess
def jstr(s):
    return '"'+s.replace('\\','\\\\').replace('"','\\"').replace('\n','\\n').replace('\r','\\r').replace('\t','\\t')+'"'
def render(n, indent, root):
    tag = 'doc' if root else n['tag']
    out = ' '*indent + tag
    if 'pos' in n and not root:
        p=n['pos']; out += f" ({p['start']['line']}:{p['start']['col']}:{p['start']['offset']}-{p['end']['line']}:{p['end']['col']}:{p['end']['offset']})"
    t=n['tag']
    if t in ('str','verbatim','raw_inline','raw_block','code_block','footnote_reference','symb'):
        if t=='symb':
            if n.get('alias'): out += ' alias='+jstr(n['alias'])
        elif n.get('text'): out += ' text='+jstr(n['text'])
    elif t=='heading': out += f" level={n['level']}"
    elif t=='bullet_list':
        out += ' tight=true' if n.get('tight') else ' tight=false'
        if n.get('style'): out += ' style='+jstr(n['style'])
    elif t=='ordered_list': out += ' tight=true' if n.get('tight') else ' tight=false'
    elif t=='task_list_item':
        if 'checkbox' in n: out += ' checked=true' if n['checkbox']=='checked' else ' checked=false'
    elif t in ('link','image','url','email'):
        if n.get('destination') is not None: out += ' destination='+jstr(n['destination'])
        if n.get('reference'): out += ' reference='+jstr(n['reference'])
    elif t=='row': out += ' head=true' if n.get('head') else ' head=false'
    elif t=='cell':
        out += ' head=true' if n.get('head') else ' head=false'
        out += ' align="%s"' % n.get('align','default')
    if n.get('lang') is not None: out += ' lang='+jstr(n['lang'])
    attrs = n.get('attributes') or {}
    if 'id' in attrs: out += ' id='+jstr(attrs['id'])
    if 'class' in attrs: out += ' class='+jstr(attrs['class'])
    for k,v in attrs.items():
        if k in ('id','class'): continue
        out += f' {k}={jstr(v)}'
    lines=[out]
    for c in n.get('children',[]): lines.append(render(c, indent+2, False))
    return '\n'.join(lines)
def convert(djot_input, sourcepos):
    args=['npx','-y','@djot/djot@0.3.2','-t','ast']+(['-p'] if sourcepos else [])
    r=subprocess.run(args,input=djot_input.encode(),capture_output=True)
    return render(json.loads(r.stdout), 0, True)+'\n'
if __name__=='__main__':
    sourcepos = '-p' in sys.argv[1:]
    sys.stdout.write(convert(sys.stdin.read(), sourcepos))
