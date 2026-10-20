// Unit-test actual PhonePage script with a minimal DOM, without launching a browser.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
class Element {
 constructor(tag='div'){this.tagName=tag.toLowerCase();this.children=[];this.value='';this.checked=false;this.hidden=false}
 append(...children){this.children.push(...children)}
 replaceChildren(...children){this.children=children}
 all(){return this.children.filter(c=>c instanceof Element).flatMap(c=>[c,...c.all()])}
 querySelectorAll(selector){return this.all().filter(node=>selector.split(',').some(s=>{s=s.trim();if(s==='select')return node.tagName==='select';if(s.includes('name=choice]'))return node.tagName==='input'&&node.name==='choice'&&(!s.endsWith(':checked')||node.checked);if(s.includes('name=choices]'))return node.tagName==='input'&&node.name==='choices'&&(!s.endsWith(':checked')||node.checked);return node.tagName===s}))}
}
const nodes=new Map(),storage=new Map();const get=id=>{for(const root of nodes.values()){const child=root.all().find(n=>n.id===id);if(child)return child}if(!nodes.has(id))nodes.set(id,new Element());return nodes.get(id)};
const document={getElementById:get,createElement:tag=>new Element(tag),createTextNode:text=>({textContent:text}),addEventListener(){},querySelector:s=>[...nodes.values()].flatMap(n=>n.querySelectorAll(s))[0]??null,querySelectorAll:s=>[...nodes.values()].flatMap(n=>n.querySelectorAll(s))};
const source=fs.readFileSync('Sources/QuizStudio/PhonePage.swift','utf8').split('<script>')[1].split('</script>')[0];
const context={document,location:{pathname:'/test/'},localStorage:{getItem:k=>storage.get(k)??null,setItem:(k,v)=>storage.set(k,v)},crypto:require('node:crypto').webcrypto,console,setTimeout,clearTimeout,AbortController,fetch(){throw Error('No network expected')},assert};
vm.createContext(context);vm.runInContext(source+`
active={kind:'Несколько вариантов',question:'multi',choices:['2','3','4','5']};build(active);
let boxes=$('fields').querySelectorAll('input[name=choices]:checked');assert.equal(boxes.length,0);
let inputs=$('fields').all().filter(n=>n.tagName==='input');inputs[0].checked=true;inputs[2].checked=true;rememberDraft();assert.equal(JSON.stringify(draft().choices),'[0,2]');build(active);assert.equal(JSON.stringify(draft().choices),'[0,2]');
active={kind:'Порядок событий',question:'order',sequence:['Последнее','Среднее','Первое']};build(active);let selects=$('fields').querySelectorAll('select');selects.forEach((n,i)=>n.value=String(2-i));rememberDraft();assert.equal(JSON.stringify(draft().order),'[2,1,0]');build(active);assert.equal(JSON.stringify(draft().order),'[2,1,0]');
active={kind:'Числовой ответ',question:'number'};build(active);$('textAnswer').value='1,5';assert.equal(draft().text,'1,5');assert.equal($('textAnswer').inputMode,'decimal');
active={kind:'Сопоставление',question:'match',left:[{key:'l0',text:'A'},{key:'l1',text:'B'}],right:[{key:'r0',text:'1'},{key:'r1',text:'2'}]};build(active);selects=$('fields').querySelectorAll('select');selects[0].value='r1';selects[1].value='r0';assert.equal(JSON.stringify(draft().matches),'{"l0":"r1","l1":"r0"}');
console.log('PASS: actual phone form script builds checkbox/order/numeric fields, sends expected payloads, restores drafts and preserves matching answers');`,context);
