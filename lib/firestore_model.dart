library firestore_model;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
// ignore: deprecated_member_use
import 'package:collection/equality.dart';
import 'package:synchronized_lite/synchronized_lite.dart';

import 'package:mutable_model/mutable_model.dart';

abstract class FirestoreMetaModel extends MetaModel {
  static final id = Prop<DocumentReference>();
  static final saving = BoolProp();
  static final loaded = BoolProp();

  List<Property> get properties => [saving, loaded, id] + attrs;

  List<StoredProperty> get attrs;
}

abstract class FirestoreModel extends Model with Lock {

  Map<String, dynamic> data;

  FirestoreModel(FirestoreMetaModel meta): super(meta);

  FirestoreMetaModel get meta => super.meta as FirestoreMetaModel;

  CollectionReference get collectionRef;

  bool get exists => docRef != null;
  DocumentReference get docRef => get(FirestoreMetaModel.id);
  void set docRef(DocumentReference value) => set(FirestoreMetaModel.id, value);
  bool get loaded => get(FirestoreMetaModel.loaded);
  void set loaded(bool v) => set(FirestoreMetaModel.loaded, v);
  bool get saving => get(FirestoreMetaModel.saving);
  void set saving(bool v) => set(FirestoreMetaModel.saving, v);

  void init(DocumentSnapshot snapshot) {
    assert(snapshot.exists);
    this.docRef = snapshot.reference;
    readFrom(snapshot.data);
  }

  void readFrom(Map<String, dynamic> data, [List<StoredProperty> attrs]) {
    if(data == null)
      return;
    for(var attr in attrs ?? this.meta.attrs)
      attr.readFrom(data);
    loaded = true;
  }

  void writeTo(Map<String, dynamic> data, [List<StoredProperty> attrs]) {
    for(var attr in attrs ?? this.meta.attrs)
      attr.writeTo(snapshot[attr], data);
  }

  Future<DocumentReference> create() async {
    await save();
    return docRef;
  }

  Future<bool> save() async {
    return await synchronized<bool>(() async {
      try {
        if(exists) {
          var changes = getChanges();
          print("${docRef.path}: save: ${changes.keys.toList()}");
          if(changes.length == 0)
            return false;
          saving = true;
          flushChanges();
          await docRef.setData(changes, merge: true);
          loaded = true;
          data.addAll(changes);
        } else {
          saving = true;
          data = createData();
          flushChanges();
          print("${collectionRef.path}: create: ${data.keys.toList()}");
          docRef = await collectionRef.add(data);
        }
        return true;
      } finally {
        saving = false;
        flushChanges();
      }
    });
  }

  bool loadFromSnapshot(DocumentSnapshot doc) {
    readFrom(doc.data);
    docRef = doc.reference;
    loaded = true;
    return flushChanges();
  }

  Future<void> load(String id) async {
    if(id == null)
      return;
    var doc = await collectionRef.document(id).get();
    loadFromSnapshot(doc);
  }

  void copyAttributesFrom(FirestoreModel other, [List<StoredProperty> props]) {
    copyFrom(other, props ?? meta.attrs);
  }

  void initTemplate() {
    data = createData();
  }

  Map<String, dynamic> getTemplateData() {
    return getChanges();
  }

  Map<String, dynamic> createData([List<StoredProperty> attrs]) {
    final data = Map<String, dynamic>();
    writeTo(data, attrs);
    return data;
  }
  
  Map<String, dynamic> getChanges([List<StoredProperty> attrs]) {
    if(data == null)
      return createData(attrs);
    else {
      final changes = Map<String, dynamic>();
      for(var attr in attrs ?? this.meta.attrs)
        attr.calcChanges(snapshot[attr], data, changes);
      return changes;
    }
  }

  
}

typedef T ElementFactory<T>(DocumentSnapshot doc);

StreamSubscription<QuerySnapshot> createModelSubscription<T extends FirestoreModel>({
  OrderedMap<String, T>collection,
  ElementFactory<T> factory,
  Query query}) {
  return query.snapshots().listen(
    (snapshots) {
      for(var change in snapshots.documentChanges) {
        var doc = change.document;
        if(change.type == DocumentChangeType.removed) {
          collection.remove(doc.documentID);
        } else if(collection.containsKey(doc.documentID)) {
          collection[doc.documentID].loadFromSnapshot(doc);
        } else {
          collection.put(doc.documentID,  factory(doc));
        }
      }
    }
  );
}

abstract class StoredProperty<T> implements Property<T> {
  final Property<T> prop;
  int index;

  StoredProperty(this.prop);

  dynamic store(T value) => prop.store(value);
  T load(dynamic value) => prop.load(value);
  bool dataEquals(dynamic a, dynamic b) => prop.dataEquals(a, b);
  T get initial => prop.initial;

  dynamic readFrom(Map<dynamic, dynamic> data);

  void writeTo(dynamic modelData, Map<dynamic, dynamic> data);

  void calcChanges(dynamic modelData, Map<dynamic, dynamic> data, Map<dynamic, dynamic> changes);
  
}

class Attribute<T> extends StoredProperty<T> {

  final String name;

  Attribute(this.name, Property<T> attr): super(attr);

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
    if(!changes.containsKey(name) || !dataEquals(modelData, changes[name]))
      changes[name] = modelData;
  }
  
  Query whereEquals(T value, Query src) {
    return src.where(name, isEqualTo: prop.store(value));
  }

  Query whereLessThan(T value, Query src) {
    return src.where(name, isLessThan: prop.store(value));
  }

  Query orderBy(Query src, {descending: false}) {
    return src.orderBy(name, descending: descending);
  }

  Query startAt(T value, Query src) {
    return src.startAt([prop.store(value)]);
  }

  Query startAfter(T value, Query src) {
    return src.startAfter([prop.store(value)]);
  }

  Query endBefore(T value, Query src) {
    return src.endBefore([prop.store(value)]);
  }

  Query endAt(T value, Query src) {
    return src.endAt([prop.store(value)]);
  }
}

//typedef T Factory<T>();
class ListAttribute<T> extends StoredProperty<List<T>> {

  final String prefix;

  ListAttribute(this.prefix, ListProp<T> prop): super(prop);

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
        data[key] = list[i].data;
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

  TimestampProperty([DateTime initialValue]): super(initialValue);

  @override
  DateTime load(dynamic data) {
    if(data is FieldValue)
      return null; // Special handling for server timestamp
    if(data == null)
      return null;
    if(data is DateTime)
      return data;
    final ts = data as Timestamp;
    return DateTime.fromMicrosecondsSinceEpoch(ts.microsecondsSinceEpoch, isUtc: true);
  }

  @override
  dynamic store(DateTime dt) {
    return dt == null ? null : Timestamp.fromMicrosecondsSinceEpoch(dt.toUtc().microsecondsSinceEpoch);
  }

  dynamic serverTimestamp() {
    return FieldValue.serverTimestamp();
  }

}

class TimestampAttr extends Attribute<DateTime> {

  TimestampAttr(String name, [DateTime initialValue]): super(name, TimestampProperty(initialValue));

  dynamic serverTimestamp() {
    (prop as TimestampProperty).serverTimestamp();
  }

}

/// Stores GeoPoint value as-is
class GeoPointProp extends Prop<GeoPoint> {

  GeoPointProp([GeoPoint initialValue]): super(initialValue);

}

/// Stores a document reference
class DocRefProp extends Prop<DocumentReference> {

  final CollectionReference collectionRef;

  DocRefProp(this.collectionRef, [DocumentReference initialValue]): super(initialValue);

  @override
  DocumentReference load(data) {
    if(data is String)
      return collectionRef.document(data);
    else if(data is DocumentReference)
      return data;
    else
      return null;
  }

  @override
  dynamic store(DocumentReference dr) {
    if(dr == null)
      return null;
    else {
      assert(dr.path.startsWith(collectionRef.path));
      return dr;
    }
  }

}


/// Stores the entire model as a value. Does not store model's ID
abstract class FirestoreModelProp<M extends FirestoreModel> extends MapProp<M> {
  
  M createModel();

  List<StoredProperty> getStoredAttrs(M model) => model.meta.attrs;
  
  @override
  M load(data) {
    if(data == null) {
      return null;
    } else {
      M model = createModel();
      model.readFrom(Map.castFrom<dynamic, dynamic, String, dynamic>(data));
      return model;
    }
  }

  @override
  dynamic store(M model) {
    if(model == null) {
      return null;
    } else {
      final data = model.createData();
      model.writeTo(data);
      return data;
    }
  }
  
}
