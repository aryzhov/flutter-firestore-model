# firestore_model

Read-write model objects for Firebase Cloud Firestore backend based on mutable_model package.

## Example

```dart
import 'package:firestore_model/firestore_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ProductAttributes {
  static Attribute<String> category([String value]) => Attribute('category', SimpleProperty<String>(value));
  static Attribute<String> name([String value]) => Attribute('name', SimpleProperty<String>(value));
  static Attribute<int> stock([int value]) => Attribute('stock', IntProperty(value));
  static Attribute<bool> onSale([bool value]) => Attribute('onSale', BoolProperty(value));
  static Attribute<double> price([double value]) => Attribute('price', DoubleProperty(value));
  static TimestampAttr created([DateTime value]) => TimestampAttr('created', value);
}

class Product extends FirestoreModel {
  static final productsRef = Firestore.instance.collection('products'); 
  
  final category = ProductAttributes.category();
  final name = ProductAttributes.name();
  final stock = ProductAttributes.stock();
  final onSale = ProductAttributes.onSale();
  final price = ProductAttributes.price();
  final created =  ProductAttribtues.created();

  get collectionRef => productsRef;   

  static List<Product> getProductsByName(String name) async {
    return (await ProductAttributes.name(name).whereEquals(
      Product.productsRef
    ).getDocuments()).map((snapshot) => Product()..init(snapshot)).toList();
  }
}
```
