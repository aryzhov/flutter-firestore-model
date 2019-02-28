library firestore_model;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collection/equality.dart';
import 'package:synchronized_lite/synchronized_lite.dart';

import 'package:mutable_model/model.dart';
import 'package:mutable_model/properties.dart';
import 'package:mutable_model/ordered_map.dart';

abstract class FirestoreModel extends MutableModel<Mutable> with Lock {

  Map<String, dynamic> data;
  final id = SimpleProperty<DocumentReference>();
  final saving = BoolProp();
  final loaded = BoolProp();
  List<Mutable> _properties;

  List<StoredProperty> get attrs;

  List<Mutable> get properties {
    if(_properties == null)
      _properties = <Mutable>[saving, loaded, id] + attrs;
    return _properties;
  }

  CollectionReference get collectionRef;

  DocumentReference get docRef => id.value;
  set docRef(DocumentReference value) => id.value = value;

  get exists => docRef != null;

  void init(DocumentSnapshot snapshot) {
    assert(snapshot.exists);
    this.docRef = snapshot.reference;
    readFrom(snapshot.data);
  }

  void readFrom(Map<String, dynamic> data) {
    if(data == null)
      return;
    for(var attr in attrs)
      attr.readFrom(data);
    this.data = data;
    loaded.value = true;
  }

  void writeTo(Map<String, dynamic> data) {
    for(var attr in attrs)
      attr.writeTo(data);
  }

  Future<DocumentReference> create() async {
    await save();
    return docRef;
  }

  Future<bool> save() async {
    return await synchronized<bool>(() async {
      var newData = createData(attrs);
      try {
        if(exists) {
          var changes = getChanges(newData, data);
          print("${collectionRef.path}/$id: save: ${changes.keys.toList()}");
          if(changes.length == 0)
            return false;
          saving.value = true;
          flushChanges();
          await docRef.setData(changes, merge: true);
          loaded.value = true;
        } else {
          saving.value = true;
          flushChanges();
          print("${collectionRef.path}: create: ${newData.keys.toList()}");
          docRef = await collectionRef.add(newData);
        }
        data = newData;
        return true;
      } finally {
        saving.value = false;
        flushChanges();
      }
    });
  }

  bool loadFromSnapshot(DocumentSnapshot doc) {
    readFrom(doc.data);
    docRef = doc.reference;
    loaded.value = true;
    return flushChanges();
  }

  Future<void> load(String id) async {
    if(id == null)
      return;
    var doc = await collectionRef.document(id).get();
    loadFromSnapshot(doc);
  }

  void copyFrom(FirestoreModel other, [List<StoredProperty> props]) {
    List<Attribute> attrs = (props ?? this.attrs).where((attr) => attr is Attribute).map((attr) => attr as Attribute).toList();
    var attrMap = Map.fromEntries(attrs.map((attr) => MapEntry<String, StoredProperty>(attr.name, attr)));
    var data = Map<String, dynamic>();
    for(var attr0 in other.attrs) {
      if(attr0 is Attribute && attrMap.containsKey(attr0.name)) {
        var attr = attrMap[attr0.name];
        attr0.writeTo(data);
        attr.readFrom(data);
      }
    }
  }

  void initTemplate() {
    data = createData(attrs);
  }

  Map<String, dynamic> getTemplateData() {
    final newData = createData(attrs);
    final changes = getChanges(newData, data);
    return changes;
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


abstract class StoredProperty<T> extends Mutable<T> {


  void readFrom(Map<dynamic, dynamic> data);

  void writeTo(Map<dynamic, dynamic> data);

}

class Attribute<T> extends StoredProperty<T> {

  final String _name;
  final Property<T> attr;

  Attribute(this._name, this.attr);

  get name => _name;
  bool get changed => attr.changed;
  set changed(bool c) {
    attr.changed = c;
  }

  @override
  void readFrom(Map<dynamic, dynamic> data) {
    if(!data.containsKey(_name)) {
      attr.data = null;
    } else {
      var attrData = data[_name];
      attr.data = attrData;
    }
  }

  T get value => attr.value;

  set value(v) {
    attr.value = v;
  }

  bool get isNull => attr.data == null;

  @override
  void writeTo(Map<dynamic, dynamic> data) {
    data[_name] = attr.data;
  }

  Query whereEquals(Query src) {
    return src.where(_name, isEqualTo: attr.data);
  }

  Query whereLessThan(Query src) {
    return src.where(_name, isLessThan: attr.data);
  }

}


typedef Property<T> AttributeFactory<T>();


class ListAttribute<T> extends StoredProperty<List<T>> {

  String _prefix;
  AttributeFactory<T> factory;
  var list = List<Property<T>>();
  bool _changed = false;

  ListAttribute(this._prefix, this.factory);

  get name => _prefix;
  get changed => _changed || list.length > 0 ? list.map((attr) => attr.changed).reduce((a, b) => a || b) : false;
  set changed(c) {
    this._changed = c;
    if(!c)
      for(var attr in list)
        attr.changed = false;
  }

  void append(T value) {
    var attr = factory();
    attr.value = value;
    list.add(attr);
    changed = true;
  }

  @override
  List<T> get value => list.map((el) => el.value).toList();

  @override
  set value(List<T> value) {
    list = value.map((el) => factory()..value = el).toList();
    changed = true;
  }

  @override
  void readFrom(Map<dynamic, dynamic> data) {
    while(true) {
      var key = '$_prefix${list.length}';
      if(!data.containsKey(key))
        break;
      var attr = factory();
      attr.data = data[key];
      list.add(attr);
      changed = true;
    }
  }

  @override
  void writeTo(Map<dynamic, dynamic> data) {
    for(var i = 0; i < list.length; i++) {
      var key = '$_prefix$i';
      data[key] = list[i].data;
    }
  }

}

Map<String, dynamic> createData(List<StoredProperty> attrs) {
  final data = Map<String, dynamic>();
  for(var attr in attrs)
    attr.writeTo(data);
  return data;
}

final equality = DeepCollectionEquality.unordered();

Map<String, dynamic> getChanges(Map<String, dynamic> data, Map<String, dynamic> oldData) {
  if(oldData == null || oldData.length == 0)
    return data;
  final changes = Map.of(data)..removeWhere((k, v) {
    // this code is verbose for debugging
    if(!oldData.containsKey(k))
      return false;
    bool eq = equality.equals(v, oldData[k]);
    return eq;
  });
  return changes;
}

class TimestampProperty extends Property<DateTime> {

  TimestampProperty([DateTime initialValue]) {
    if(initialValue != null)
      value = initialValue;
  }

  get value {
    if(data is FieldValue)
      return null; // Special handling for server timestamp
    if(data == null)
      return null;
    final ts = data as Timestamp;
    return DateTime.fromMicrosecondsSinceEpoch(ts.microsecondsSinceEpoch);
  }

  set value(dt) {
    data = dt == null ? null : Timestamp.fromMicrosecondsSinceEpoch(dt.microsecondsSinceEpoch);
  }

  void setServerTimestamp() {
    data = FieldValue.serverTimestamp();
  }

}

class TimestampAttr extends Attribute<DateTime> {

  TimestampAttr(String name, [DateTime initialValue]): super(name, TimestampProperty(initialValue));

  void setServerTimestamp() {
    (attr as TimestampProperty).setServerTimestamp();
  }

}

class DocRefProperty extends Property<DocumentReference> {

  final CollectionReference collectionRef;

  DocRefProperty(this.collectionRef, [DocumentReference initialValue]) {
    if(initialValue != null)
      value = initialValue;
  }

  @override
  DocumentReference get value {
    if(data == null)
      return null;
    final id = data as String;
    return collectionRef.document(id);
  }

  @override
  set value(DocumentReference dr) {
    if(dr == null)
      data = null;
    else {
      assert(dr.path.startsWith(collectionRef.path));
      data = dr.documentID;
    }
  }

}