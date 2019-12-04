library firestore_model;

import 'dart:async';
import 'dart:js' as js;

import 'package:firebase/firestore.dart';
import 'package:mutable_model/mutable_model.dart';
import 'package:synchronized_lite/synchronized_lite.dart';

abstract class FirestoreMetaModel extends StoredMetaModel {
  static final id = Prop<DocumentReference>();

  CollectionReference get collectionRef;

  @override
  List<Property> get properties => StoredMetaModel.storedModelProperties + <Property>[FirestoreMetaModel.id] + List.castFrom<StoredProperty, Property>(cachedAttrs) + extraProperties;

  List<Property> get extraProperties => [];

}

abstract class FirestoreModel extends StoredModel with Lock {

  FirestoreModel(FirestoreMetaModel meta): super(meta);

  @override
  FirestoreMetaModel get meta => super.meta as FirestoreMetaModel;

  bool get exists => data != null;
  DocumentReference get docRef => get(FirestoreMetaModel.id);
  set docRef(DocumentReference value) => set(FirestoreMetaModel.id, value);

  void init(DocumentSnapshot snapshot) {
    assert(snapshot.exists);
    this.docRef = snapshot.ref;
    readFrom(snapshot.data());
    flushChanges();
  }

  Future<DocumentReference> create() async {
    await save();
    return docRef;
  }

  Future<bool> save() async {
    return await synchronized<bool>(() async {
      try {
        if(docRef != null) {
          var changes = getChanges();
          // print("${docRef.path}: save: ${changes.keys.toList()}");
          if(changes.isEmpty)
            return false;
          saving = true;
          flushChanges();
          // print("Changes: $changes");
          final sanitized = sanitize(changes);
          await docRef.set(sanitized, SetOptions(merge: true));
          loaded = true;
          if(data == null)
            data = changes;
          else
            data.addAll(changes);
        } else {
          saving = true;
          data = createData();
          flushChanges();
          // print("${meta.collectionRef.path}: create: ${data.keys.toList()}");
          final sanitized = sanitize(data);
          docRef = await meta.collectionRef.add(sanitized);
        }
        return true;
      } catch(e) {
        print("Save error: $e");
        return false;
      } finally {
        saving = false;
        flushChanges();
      }
    });
  }

  bool loadFromSnapshot(DocumentSnapshot doc) {
    readFrom(doc.data());
    docRef = doc.ref;
    loaded = true;
    return flushChanges();
  }

  Future<void> load(String id) async {
    if(id == null)
      return;
    var doc = await meta.collectionRef.doc(id).get();
    loadFromSnapshot(doc);
  }

  void initTemplate() {
    data = createData();
  }

  Map<String, dynamic> getTemplateData() {
    return getChanges();
  }

}

typedef T ElementFactory<T>(DocumentSnapshot doc);

StreamSubscription<QuerySnapshot> createModelSubscription<T extends FirestoreModel>({
  ModelMap<String, T>collection,
  ElementFactory<T> factory,
  Query query}) {
  return query.onSnapshot.listen(
    (snapshots) {
      try {
        // print("Got a snapshot");
        for(var change in snapshots.docChanges()) {
          var doc = change.doc;
          if(change.type == 'removed') {
            // print("   Removed element: ${doc.id}");
            collection.remove(doc.id);
          } else if(collection.containsKey(doc.id)) {
            // print("   Changed element: ${doc.id}");
            collection[doc.id].loadFromSnapshot(doc);
          } else {
            // print("   Added element: ${doc.id}");
            collection.put(doc.id,  factory(doc));
          }
        }
        collection.loaded = true;
        // print("Done with snapshot");
      } catch(e) {
        print("Error in onSnapshot: $e");
      }
    }
  , onError: (e) {
    print("Error: $e");
  });
}

class Attribute<T> extends StoredProperty<T> {

  Attribute(String name, Property<T> attr): super(name, attr);

  @override
  dynamic readFrom(Map<dynamic, dynamic> data) {
    if(!data.containsKey(name)) {
      return null;
    } else {
      return data[name];
    }
  }

  @override
  void writeTo(dynamic modelData, Map<dynamic, dynamic> data) {
    data[name] = modelData;
  }

  void calcChanges(dynamic modelData, Map<dynamic, dynamic> data, Map<dynamic, dynamic> changes) {
    if(!data.containsKey(name) || !dataEquals(modelData, data[name]))
      changes[name] = modelData;
  }

  Query whereEquals(T value, Query src) {
    return src.where(name, '==', prop.store(value));
  }

  Query whereLessThan(T value, Query src) {
    return src.where(name, '<', prop.store(value));
  }

  Query orderBy(Query src, {descending = false}) {
    return src.orderBy(name, descending ? 'desc': 'asc');
  }

  Query startAt(T value, Query src) {
    return src.startAt(fieldValues: [prop.store(value)]);
  }

  Query startAfter(T value, Query src) {
    return src.startAfter(fieldValues: [prop.store(value)]);
  }

  Query endBefore(T value, Query src) {
    return src.endBefore(fieldValues: [prop.store(value)]);
  }

  Query endAt(T value, Query src) {
    return src.endAt(fieldValues: [prop.store(value)]);
  }
}

class ListAttribute<T> extends StoredProperty<List<T>> {

  String get prefix => name;

  ListAttribute(String prefix, ListProp<T> prop): super(prefix, prop);

  @override
  dynamic readFrom(Map<dynamic, dynamic> data) {
    final list = List<dynamic>();
    while(true) {
      var key = '$prefix${list.length}';
      if(!data.containsKey(key))
        break;
      list.add(data[key]);
    }
    return list;
  }

  @override
  void writeTo(dynamic modelData, Map<dynamic, dynamic> data) {
    final list = modelData as List;
    if(list != null) {
      for(var i = 0; i < list.length; i++) {
        var key = '$prefix$i';
        data[key] = list[i];
      }
    }
  }

  void calcChanges(dynamic modelData, Map<dynamic, dynamic> data, Map<dynamic, dynamic> changes) {
    if(modelData is List) {
      for(var i = 0; i < modelData.length; i++) {
        var key = '$prefix$i';
        if(!data.containsKey(key) || !(prop as ListProp<T>).element.dataEquals(modelData[i], data[key]))
          changes[key] = modelData[i];
      }
    }
  }
  
}

class TimestampProperty extends Prop<DateTime> {

  final bool isUtc;
  
  TimestampProperty({DateTime initialValue, this.isUtc = true}): super(initialValue);

  @override
  DateTime load(dynamic data) {
    if(data is DateTime) {
      return isUtc ? data.toUtc(): data.toLocal();
    } else {
      return null;
    }
  }

  @override
  dynamic store(DateTime dt) {
    // Changed from Timestamp
    return dt;
  }

  dynamic serverTimestamp() {
    return FieldValue.serverTimestamp();
  }

}

class TimestampAttr extends Attribute<DateTime> {

  TimestampAttr(String name, {DateTime initialValue, bool isUtc = true}): super(name, TimestampProperty(initialValue: initialValue, isUtc: isUtc));

  dynamic serverTimestamp() {
    return (prop as TimestampProperty).serverTimestamp();
  }

}

/// Stores GeoPoint value as-is
class GeoPointProp extends Prop<GeoPoint> {

  GeoPointProp([GeoPoint initialValue]): super(initialValue);

}

/// Stores a document reference
class DocRefProp extends Prop<DocumentReference> {

  DocRefProp([DocumentReference initialValue]): super(initialValue);

  @override
  DocumentReference load(data) {
    return data as DocumentReference;
  }

  @override
  dynamic store(DocumentReference dr) {
    return dr;
  }

}

typedef T Factory<T>();

/// Stores the entire model as a value. Does not store model's ID
class StoredModelProp<M extends StoredModel> extends MapProp<M> {

  final Factory<M> factory;
  final List<StoredProperty> storedAttrs;
  final bool allowNull;

  StoredModelProp(this.factory, this.storedAttrs, {this.allowNull = true});

  @override
  M load(data) {
    if(data == null) {
      return allowNull ? null: factory();
    } else {
      M model = factory();
      model.readFrom(Map.castFrom<dynamic, dynamic, String, dynamic>(data), storedAttrs);
      return model;
    }
  }

  @override
  dynamic store(M model) {
    if(model == null && allowNull) {
      return null;
    } else {
      return (model ?? factory()).createData(storedAttrs);
    }
  }
  
}


/// An obscure way to declare a null value that will be passed as null in js-interop calls.
final _null = (() => new js.JsObject.jsify({'a': null})['a'])();

/// This function exists as a workaround for https://github.com/dart-lang/sdk/issues/27485
/// (dart2js functions sometimes return undefined instead of null).
/// Since the value undefined cannot be used in firebase functions, we need to replace 
/// undefined with null.
T sanitize<T>(T value) {
  if(value == null) {
    return _null;
  } else if(value is Map) {
    return Map<String, dynamic>.fromEntries(value.entries.map((me) => MapEntry(me.key, sanitize(me.value)))) as T;
  } else if(value is List) {
    return (value as List<dynamic>).map((el) => sanitize(el)).toList() as T;
  } else {
    return value;
  }
}