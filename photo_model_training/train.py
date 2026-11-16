"""FORMA: isolated, opt-in YOLO training from a local labelled dataset.
Outputs are never connected to game controls or the existing ONNX runtime.
"""
import argparse, hashlib, json, math, os, re, sys, time
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
WEIGHTS = Path(__file__).resolve().parent / 'yolov8n.pt'
WEIGHTS_SHA = 'f59b3d833e2ff32e194b5bb8e08d211dc7c5bdf144b90d2c8412c47ccfc83b36'
EXT = {'.jpg', '.jpeg', '.png', '.bmp'}

def say(s):
    print(s, flush=True)

def sha(p, max_bytes=None):
    h = hashlib.sha256(); total = 0
    with p.open('rb') as f:
        while b := f.read(1024 * 1024):
            total += len(b)
            if max_bytes is not None and total > max_bytes:
                raise ValueError('файл больше допустимого размера')
            h.update(b)
    return h.digest()

def find_dataset(base):
    # Only known layouts, never recursively include bot-generated snapshots/auto.
    for root in (base / 'фото_для_модели', base / 'snapshots'):
        if (root / 'data.yaml').is_file() and all((root / p / d).is_dir() for p in ('train','valid') for d in ('images','labels')):
            return root.resolve()
    raise ValueError('Не найден набор с data.yaml и train/valid/images, train/valid/labels. Положите набор в snapshots или фото_для_модели рядом с AHK.')

def schema(root):
    p = root / 'data.yaml'
    if p.stat().st_size > 65536: raise ValueError('data.yaml слишком большой')
    text = p.read_text(encoding='utf-8-sig')
    if not re.search(r'(?m)^\s*nc\s*:\s*1\s*(?:#.*)?$', text): raise ValueError('Ожидается nc: 1 в data.yaml')
    m = re.search(r'''(?mi)^\s*names\s*:\s*\[\s*['"]?(enemy|player)['"]?\s*\]\s*(?:#.*)?$''', text)
    if not m: raise ValueError("Ожидается names: ['enemy'] или names: ['player'] в data.yaml")
    return m.group(1).lower()

class UnsupportedClasses(ValueError):
    """A syntactically valid label includes IDs not declared in data.yaml."""
    def __init__(self, ids):
        self.ids = sorted(ids)
        super().__init__('классы вне data.yaml: ' + ','.join(map(str, self.ids)))

def boxes(path, data=None):
    if data is None:
        if path.stat().st_size > 1000000: raise ValueError('слишком большой файл разметки')
        with path.open('rb') as f:
            data = f.read(1000001)
    if len(data) > 1000000: raise ValueError('слишком большой файл разметки')
    lines = data.decode('utf-8-sig').splitlines()
    n = 0
    unsupported = set()
    for line in lines:
        if not line.strip(): continue
        a = line.split()
        if len(a) != 5 or not re.fullmatch(r'0|[1-9][0-9]*', a[0]):
            raise ValueError('ожидается YOLO: номер класса и 4 координаты')
        cls = int(a[0])
        x,y,w,h = map(float,a[1:])
        if not all(math.isfinite(v) for v in (x,y,w,h)) or not (0<x<1 and 0<y<1 and 0<w<=1 and 0<h<=1) or x-w/2 < -0.002 or x+w/2 > 1.002 or y-h/2 < -0.002 or y+h/2 > 1.002:
            raise ValueError('неверные координаты рамки')
        if cls != 0: unsupported.add(cls)
        n += 1
    if unsupported: raise UnsupportedClasses(unsupported)
    return n

def audit(root):
    cls = schema(root); seen = {}; result = {}; errors = []; unexpected = set()
    for part in ('train','valid','test'):
        imdir, labdir = root / part / 'images', root / part / 'labels'
        if not imdir.is_dir() or not labdir.is_dir():
            if part != 'test': raise ValueError('Не найдены images/labels для ' + part)
            continue
        paths = sorted((p for p in imdir.iterdir() if p.is_file() and p.suffix.lower() in EXT), key=lambda p:p.name.lower())
        if len(paths)>30000: raise ValueError('Больше 30000 изображений в одном разделе')
        accepted=[]; missing=0; duplicates=0; positives=0; negatives=0; stems=set(); skipped=0
        for i,p in enumerate(paths):
            if i % 250 == 0: say(f'Проверка {part}: {i}/{len(paths)}')
            if p.stem.lower() in stems:
                errors.append(f'{part}: одинаковое имя изображения {p.stem}')
                continue
            stems.add(p.stem.lower())
            lab = labdir / (p.stem + '.txt')
            if not lab.is_file(): missing += 1; continue
            try:
                if p.stat().st_size > 50*1024*1024: raise ValueError('файл больше 50 МБ')
                if lab.stat().st_size > 1000000: raise ValueError('слишком большой файл разметки')
                # Разбор и хэш относятся к одним и тем же байтам подписи.
                with lab.open('rb') as f:
                    label_bytes = f.read(1000001)
                n = boxes(lab, label_bytes)
                label_digest = hashlib.sha256(label_bytes).digest()
                digest = sha(p, 50*1024*1024)
            except UnsupportedClasses as e:
                # Never drop only the unsupported boxes: a partially labelled image
                # would teach the detector that those objects are background.
                skipped += 1; unexpected.update(e.ids); continue
            except (ValueError, OSError, UnicodeError) as e:
                errors.append(f'{part}/{p.name}: {e}'); continue
            if digest in seen:
                duplicates += 1
                continue
            seen[digest] = part
            accepted.append((p,lab,digest,label_digest)); positives += n; negatives += n == 0
        result[part] = {'images':len(paths),'accepted':len(accepted),'missing_labels':missing,'duplicates':duplicates,'boxes':positives,'empty_labels':negatives,'skipped_unknown_class':skipped,'files':accepted}
        say(f'{part}: изображений {len(paths)}, подходят {len(accepted)}, рамок {positives}, без txt {missing}, дубликатов исключено {duplicates}, кадров с неизвестными классами исключено {skipped}')
    if unexpected:
        say('ВНИМАНИЕ: классы ' + ','.join(map(str,sorted(unexpected))) + ' не описаны в data.yaml. Кадры с ними целиком исключены; исходные файлы не менялись. Метрики относятся только к оставшимся кадрам.')
    if errors: raise ValueError('Другие ошибки разметки, обучение остановлено: ' + '; '.join(errors[:6]))
    for p in ('train','valid'):
        if not result[p]['accepted'] or not result[p]['boxes']: raise ValueError(p + ': нет размеченных изображений с рамками')
    return cls,result

def copy_verified(src, dst, expected, max_bytes):
    # Только новая папка задания и новый файл: исходники не меняем. Ограничение
    # действует и при росте файла во время копирования. При ошибке частичное
    # задание может остаться для диагностики, но обучение не начинается.
    h = hashlib.sha256(); total = 0
    with src.open('rb') as inp, dst.open('xb') as out:
        while chunk := inp.read(1024 * 1024):
            total += len(chunk)
            if total > max_bytes:
                raise ValueError('файл вырос сверх допустимого размера при копировании: ' + src.name)
            out.write(chunk); h.update(chunk)
    if h.digest() != expected:
        raise ValueError('файл изменился после проверки: ' + src.name + '. Обучение не запущено; проверьте набор и повторите.')

def stage_dataset(data, staged):
    for part, info in data.items():
        (staged/part/'images').mkdir(parents=True)
        (staged/part/'labels').mkdir()
        for i, (im, lab, image_digest, label_digest) in enumerate(info['files']):
            # Имена не раскрывают исходные имена в отчётах. Хэши проверяют,
            # что скопированы именно проверенные изображения и подписи.
            name = f'{i:06d}'
            copy_verified(im, staged/part/'images'/(name+im.suffix.lower()), image_digest, 50*1024*1024)
            copy_verified(lab, staged/part/'labels'/(name+'.txt'), label_digest, 1000000)

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--base', type=Path, default=BASE); ap.add_argument('--check', action='store_true')
    ap.add_argument('--epochs',type=int,default=10); ap.add_argument('--imgsz',type=int,default=640); ap.add_argument('--batch',type=int,default=4)
    args=ap.parse_args()
    if not (1<=args.epochs<=200 and args.imgsz in (160,320,640) and 1<=args.batch<=16): raise ValueError('Недопустимые параметры')
    root=find_dataset(args.base.resolve()); say('Найден датасет: '+str(root)); cls,data=audit(root)
    say('Класс: '+cls+'. Автометки snapshots/auto не используются.')
    if args.check: return
    if not WEIGHTS.is_file() or sha(WEIGHTS).hex()!=WEIGHTS_SHA: raise ValueError('Не совпадает SHA-256 официальных исходных весов; обучение отменено')
    # Create separate copies: ultralytics may otherwise write cache files into the user's dataset.
    results=args.base/'forma_model'/'photo-training'; results.mkdir(parents=True,exist_ok=True)
    job=results/('job-'+time.strftime('%Y%m%d-%H%M%S')+'-'+os.urandom(4).hex()); job.mkdir()
    say('Результаты: '+str(job)); staged=job/'dataset'
    stage_dataset(data, staged)
    spec={'path':str(staged.resolve()),'train':'train/images','val':'valid/images','names':{0:cls}}
    if 'test' in data and data['test']['accepted']: spec['test']='test/images'
    config=job/'dataset.json'; config.write_text(json.dumps(spec,ensure_ascii=False),encoding='utf-8')
    # Ultralytics requires a .yaml suffix; JSON is valid YAML.
    yml=job/'dataset.yaml'; config.replace(yml)
    os.environ['YOLO_CONFIG_DIR']=str((job/'settings').resolve())
    os.environ['WANDB_MODE']='disabled'; os.environ['MLFLOW_TRACKING_URI']=''
    from ultralytics import YOLO, settings
    from ultralytics import utils
    from ultralytics.utils import checks
    utils.ONLINE=False; checks.ONLINE=False
    settings.update({'sync':False,'hub':False,'wandb':False,'mlflow':False,'tensorboard':False,'comet':False,'clearml':False})
    say('Обучение YOLO на CPU. Оно может занять много часов; остановка: Ctrl+C. Исходные фотографии не изменяются.')
    model=YOLO(str(WEIGHTS))
    model.train(data=str(yml.resolve()),epochs=args.epochs,imgsz=args.imgsz,batch=args.batch,device='cpu',workers=0,project=str(job),name='train',exist_ok=False,plots=False,verbose=True)
    best=job/'train'/'weights'/'best.pt'
    if not best.is_file(): raise ValueError('Обучение не сохранило best.pt')
    trained=YOLO(str(best)); summary={'class':cls,'source':str(root),'epochs_requested':args.epochs,'splits':{p:{k:v for k,v in x.items() if k!='files'} for p,x in data.items()},'warnings':['Images containing class IDs not declared in data.yaml were excluded in full; class 0 semantics may be inconsistent in mixed datasets','Labels were not independently verified','Exact duplicate images removed, but similar video frames can leak','Detection is not friend/foe recognition','Model is NOT connected to the game']}
    if 'test' in spec:
        say('Отдельная оценка на test (автоматически модель не включается).')
        metrics=trained.val(data=str(yml.resolve()),split='test',imgsz=args.imgsz,batch=args.batch,device='cpu',workers=0,plots=False,project=str(job),name='test')
        summary['test']={'precision':float(metrics.box.mp),'recall':float(metrics.box.mr),'map50':float(metrics.box.map50),'map50_95':float(metrics.box.map)}
    (job/'report.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
    say('Экспорт в ONNX; файл не подменяет установленную модель.')
    exported=trained.export(format='onnx',imgsz=args.imgsz,device='cpu',dynamic=False,simplify=False)
    say('ГОТОВО. Веса: '+str(best)+'; ONNX: '+str(exported)+'; отчёт: '+str(job/'report.json'))
    say('Дальше нужны проверка качества на кадрах игры, задержки и безопасность союзников. В управление этот результат НЕ подключён.')

if __name__=='__main__':
    try: main()
    except KeyboardInterrupt: say('\nОбучение прервано; установленная модель и исходные фото не менялись.'); sys.exit(130)
    except Exception as e: say('\nОШИБКА: '+str(e)); sys.exit(1)
